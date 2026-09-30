# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets>=14", "sounddevice>=0.5"]
# ///
"""豆包 vs 千问 ASR 听写 A/B。

用法:
  uv run tools/ab.py               # 回车开始录音，再回车结束（模拟按住/松手）
  uv run tools/ab.py some.wav      # 用已有音频（非 16k 单声道会用 afconvert 转）
  uv run tools/ab.py --hotwords 火山引擎,Typeless

凭证从仓库根目录 .env 读取: VOLC_SPEECH_API_KEY / DASHSCOPE_API_KEY / DASHSCOPE_BASE_URL。
每次结果追加到 results.jsonl，录音存到 recordings/。

延迟口径（都是「松手到出字」）:
  - HTTP 引擎: 松手后才能上传整段音频，延迟 = 整个请求往返。
  - 豆包一句话模式: 说话时音频已按实时节奏推流，延迟 = 最后一包发出到拿到最终结果。
"""

import argparse
import asyncio
import base64
import datetime as dt
import gzip
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
import wave

ROOT = pathlib.Path(__file__).resolve().parent
RATE = 16000
CHUNK_MS = 200

# 后付费刊例价（元）。豆包见火山引擎「豆包语音 计费说明」；
# 千问取百炼模型广场 Qwen-Audio-3.1-ASR 系列卡片价格（flash 未单独标价）。
PRICE_VOLC_FILE_PER_HOUR = 0.8     # 豆包录音文件识别 2.0（极速版走 volc.seedasr.auc）
PRICE_VOLC_STREAM_PER_HOUR = 1.0   # 豆包流式语音识别 2.0（小时版）
PRICE_QWEN_IN_PER_M = 0.8          # 千问 3.1 ASR 输入 / 百万 tokens
PRICE_QWEN_OUT_PER_M = 2.7         # 千问 3.1 ASR 输出 / 百万 tokens


def load_env():
    env = {}
    for line in (ROOT.parent / ".env").read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


# ---------- 音频 ----------

def record() -> bytes:
    import sounddevice as sd

    frames = []
    input("回车开始录音 > ")
    stream = sd.RawInputStream(samplerate=RATE, channels=1, dtype="int16",
                               callback=lambda data, *_: frames.append(bytes(data)))
    with stream:
        input("录音中… 说完回车结束 > ")
    return b"".join(frames)


def read_pcm(path: pathlib.Path) -> bytes:
    """返回 16k/16bit/mono PCM；格式不符时用 macOS afconvert 转换。"""
    try:
        with wave.open(str(path)) as w:
            if (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (RATE, 1, 2):
                return w.readframes(w.getnframes())
    except wave.Error:
        pass
    with tempfile.TemporaryDirectory() as d:
        out = pathlib.Path(d) / "a.wav"
        subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1",
                        str(path), str(out)], check=True)
        with wave.open(str(out)) as w:
            return w.readframes(w.getnframes())


def to_wav(pcm: bytes) -> bytes:
    import io

    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)
    return buf.getvalue()


def to_m4a(pcm: bytes) -> bytes:
    """HTTP 引擎上传用 16k/mono/32kbps AAC，体积约为 WAV 的 1/8。
    长音频多路并发上传原始 WAV 时连接会被断开。"""
    with tempfile.TemporaryDirectory() as d:
        src, out = pathlib.Path(d) / "a.wav", pathlib.Path(d) / "a.m4a"
        src.write_bytes(to_wav(pcm))
        subprocess.run(["afconvert", "-f", "m4af", "-d", f"aac@{RATE}", "-c", "1",
                        "-b", "32000", str(src), str(out)], check=True)
        return out.read_bytes()


def post_json(url, headers, body, timeout=180):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **headers})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:300]}")


# ---------- 豆包 ----------

VOLC_FLASH = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
VOLC_NOSTREAM = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"


def volc_context(hotwords):
    if not hotwords:
        return {}
    return {"corpus": {"context": json.dumps({"hotwords": [{"word": w} for w in hotwords]},
                                             ensure_ascii=False)}}


def doubao_flash(env, m4a, hotwords):
    body = {
        "user": {"uid": "typeless-ab"},
        "audio": {"data": base64.b64encode(m4a).decode()},
        "request": {"model_name": "bigmodel", "enable_itn": True, "enable_punc": True,
                    "enable_ddc": True, **volc_context(hotwords)},
    }
    headers = {
        "X-Api-Key": env["VOLC_SPEECH_API_KEY"],
        "X-Api-Resource-Id": "volc.seedasr.auc",
        "X-Api-Request-Id": str(uuid.uuid4()),
        "X-Api-Sequence": "-1",
    }
    d = post_json(VOLC_FLASH, headers, body)
    if "result" not in d:
        raise RuntimeError(json.dumps(d, ensure_ascii=False)[:300])
    seconds = d["audio_info"]["duration"] / 1000
    return d["result"]["text"], seconds / 3600 * PRICE_VOLC_FILE_PER_HOUR


def _frame(msg_type, flags, serial, payload):
    header = bytes([0x11, (msg_type << 4) | flags, (serial << 4) | 0x1, 0x00])
    body = gzip.compress(payload)
    return header + struct.pack(">I", len(body)) + body


def _parse(msg: bytes):
    """返回 (is_last, json_or_None)；服务端错误帧直接抛异常。"""
    hsize = (msg[0] & 0x0F) * 4
    msg_type, flags = msg[1] >> 4, msg[1] & 0x0F
    gz = (msg[2] & 0x0F) == 0x1
    p = msg[hsize:]
    if msg_type == 0b1111:
        code, size = struct.unpack(">II", p[:8])
        raise RuntimeError(f"server error {code}: {p[8:8 + size].decode(errors='replace')}")
    if flags & 0x1:
        p = p[4:]  # sequence
    (size,) = struct.unpack(">I", p[:4])
    data = p[4:4 + size]
    if gz:
        data = gzip.decompress(data)
    return bool(flags & 0x2), (json.loads(data) if data else None)


async def doubao_nostream(env, pcm, hotwords):
    import websockets

    headers = {
        "X-Api-Key": env["VOLC_SPEECH_API_KEY"],
        "X-Api-Resource-Id": "volc.seedasr.sauc.duration",
        "X-Api-Connect-Id": str(uuid.uuid4()),
    }
    req = {
        "user": {"uid": "typeless-ab"},
        "audio": {"format": "pcm", "codec": "raw", "rate": RATE, "bits": 16, "channel": 1},
        "request": {"model_name": "bigmodel", "enable_itn": True, "enable_punc": True,
                    "enable_ddc": True, **volc_context(hotwords)},
    }
    step = RATE * 2 * CHUNK_MS // 1000
    chunks = [pcm[i:i + step] for i in range(0, len(pcm), step)] or [b""]
    async with websockets.connect(VOLC_NOSTREAM, additional_headers=headers,
                                  max_size=None) as ws:
        await ws.send(_frame(0b0001, 0b0000, 0b0001, json.dumps(req).encode()))
        _parse(await ws.recv())

        async def sender():
            # 按实时节奏推流，模拟边说边传
            for i, c in enumerate(chunks):
                last = i == len(chunks) - 1
                await ws.send(_frame(0b0010, 0b0010 if last else 0b0000, 0b0000, c))
                if not last:
                    await asyncio.sleep(CHUNK_MS / 1000)
            return time.perf_counter()

        send_task = asyncio.create_task(sender())
        text, ms = "", len(pcm) / (RATE * 2) * 1000
        while True:
            is_last, d = _parse(await ws.recv())
            if d and d.get("result"):
                text = d["result"].get("text", text)
                ms = (d.get("audio_info") or {}).get("duration", ms)
            if is_last:
                break
        released = await send_task
        cost = ms / 1000 / 3600 * PRICE_VOLC_STREAM_PER_HOUR
        return text, cost, time.perf_counter() - released


# ---------- 千问 ----------

def qwen(env, m4a, hotwords, polish):
    params = {"format": "m4a", "sample_rate": str(RATE)}
    if polish:
        # 文档写了 3.1 支持原生润色但未给参数名；此参数为实测生效
        params["disfluency_removal_enabled"] = True
    if hotwords:
        params["vocabulary"] = {w: 5 for w in hotwords}
    body = {
        "model": "qwen-audio-3.1-asr-flash",
        "input": {"messages": [{"role": "user", "content": [{
            "type": "input_audio",
            "input_audio": {"data": "data:audio/mp4;base64," + base64.b64encode(m4a).decode()},
        }]}]},
        "parameters": params,
    }
    d = post_json(env["DASHSCOPE_BASE_URL"] + "/api/v1/services/aigc/multimodal-generation/generation",
                  {"Authorization": "Bearer " + env["DASHSCOPE_API_KEY"]}, body)
    o = d.get("output", d)
    text = o.get("text") or (o.get("sentence") or {}).get("text")
    if text is None:
        raise RuntimeError(json.dumps(d, ensure_ascii=False)[:300])
    u = d.get("usage", {})
    cost = (u.get("input_tokens", 0) * PRICE_QWEN_IN_PER_M
            + u.get("output_tokens", 0) * PRICE_QWEN_OUT_PER_M) / 1e6
    return text, cost


# ---------- 编排 ----------

async def timed_http(fn, *args):
    t = time.perf_counter()
    text, cost = await asyncio.to_thread(fn, *args)
    return text, cost, time.perf_counter() - t


async def run_all(env, pcm, hotwords):
    m4a = to_m4a(pcm)
    # HTTP 引擎要等「松手」后才能发；一句话模式在说话期间就在推流。
    # 为了让它们的「松手」时刻对齐，HTTP 引擎延后音频时长再发。
    duration = len(pcm) / (RATE * 2)

    async def after_release(fn, *args):
        await asyncio.sleep(duration)
        return await timed_http(fn, *args)

    engines = {
        "豆包 极速版 flash": after_release(doubao_flash, env, m4a, hotwords),
        "豆包 一句话 nostream+ddc": doubao_nostream(env, pcm, hotwords),
        "千问3.1 原文": after_release(qwen, env, m4a, hotwords, False),
        "千问3.1 润色": after_release(qwen, env, m4a, hotwords, True),
    }
    results = await asyncio.gather(*engines.values(), return_exceptions=True)
    return duration, dict(zip(engines, results))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("audio", nargs="?", help="音频文件；省略则录音")
    ap.add_argument("--hotwords", default="", help="逗号分隔的热词")
    args = ap.parse_args()
    env = load_env()
    hotwords = [w.strip() for w in args.hotwords.split(",") if w.strip()]

    if args.audio:
        src = pathlib.Path(args.audio)
        pcm = read_pcm(src)
    else:
        pcm = record()
        (ROOT / "recordings").mkdir(exist_ok=True)
        src = ROOT / "recordings" / f"{dt.datetime.now():%Y%m%d-%H%M%S}.wav"
        src.write_bytes(to_wav(pcm))

    print(f"\n音频 {len(pcm) / (RATE * 2):.1f}s  ({src.name})，识别中…\n")
    duration, results = asyncio.run(run_all(env, pcm, hotwords))

    record_row = {"time": dt.datetime.now().isoformat(timespec="seconds"), "audio": str(src),
                  "duration": round(duration, 2), "hotwords": hotwords, "results": {}}
    for name, r in results.items():
        if isinstance(r, Exception):
            print(f"■ {name}\n  ✗ {r}\n")
            record_row["results"][name] = {"error": str(r)}
        else:
            text, cost, latency = r
            per_hour = cost / duration * 3600 if duration else 0
            print(f"■ {name}   松手→出字 {latency * 1000:.0f} ms   "
                  f"本次 ¥{cost:.5f}（折合 ¥{per_hour:.3f}/小时）\n  {text}\n")
            record_row["results"][name] = {"text": text, "latency_ms": round(latency * 1000),
                                           "cost_yuan": round(cost, 6)}
    with open(ROOT / "results.jsonl", "a") as f:
        f.write(json.dumps(record_row, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    sys.exit(main())
