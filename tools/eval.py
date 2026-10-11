# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets>=14", "sounddevice>=0.5"]
# ///
"""Kay 的识别评测：把评测录音按 Kay 自己的协议和参数送给每个 provider，算字错率，结果追加到 RESULTS.md。

用法:
  uv run tools/eval.py                          # 跑 tools/recordings/eval/ 下全部用例
  uv run tools/eval.py --only 2026-10-11        # 只跑文件名含这个串的用例
  uv run tools/eval.py --cases DIR --env FILE   # 用例目录和凭证另指（在 worktree 里跑时）

用例: <name>.wav（16 kHz 单声道，可以直接从 ~/Library/Application Support/Kay/recent/ 拷）加同名 <name>.txt，
.txt 第一行不以 # 开头的就是参考文本，# 行写来源和难点。录音是本人声音，目录在 .gitignore 里，不进仓库。

和 Kay 一致的地方（改 Kay 的参数时这里一起改）:
  - 千问: qwen-audio-3.1-asr-flash-streaming，WebSocket duplex，pcm 16k，200 ms 一包，按句 ID 收最终句、
    ASCII 字母相邻时补空格（Shared/Qwen.swift）。
  - 豆包: bigmodel_nostream 一句话模式，enable_itn/punc/ddc，资源 volc.seedasr.sauc.duration（Shared/Doubao.swift）。
  - 都按实时节奏推流，延迟 = 最后一包发出（松手）到最终结果。
字错率: 去掉空白和标点、转小写后按字符算编辑距离 / 参考长度；英文按字母计，粗但稳定，只用来比较。
"""

import argparse
import asyncio
import datetime as dt
import json
import pathlib
import subprocess
import sys
import time
import unicodedata
import urllib.parse
import uuid

import ab

ROOT = pathlib.Path(__file__).resolve().parent
QWEN_MODEL = "qwen-audio-3.1-asr-flash-streaming"
STEP = ab.RATE * 2 * ab.CHUNK_MS // 1000


def load_env(path: pathlib.Path):
    env = {}
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def reference(txt: pathlib.Path) -> str:
    for line in txt.read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            return line.strip()
    raise ValueError(f"{txt.name}: 没有参考文本")


def normalize(s: str) -> str:
    s = unicodedata.normalize("NFKC", s).lower()
    return "".join(c for c in s if not c.isspace() and not unicodedata.category(c).startswith("P"))


def cer(ref: str, hyp: str) -> float:
    r, h = normalize(ref), normalize(hyp)
    prev = list(range(len(h) + 1))
    for i, rc in enumerate(r, 1):
        cur = [i] + [0] * len(h)
        for j, hc in enumerate(h, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rc != hc))
        prev = cur
    return prev[-1] / max(len(r), 1)


# ---------- 千问流式（Shared/Qwen.swift 的同一套） ----------

def join_sentences(parts):
    text = ""
    for s in parts:
        if text and s and text[-1].isascii() and not text[-1].isspace() and s[0].isascii() and s[0].isalpha():
            text += " "
        text += s
    return text


async def qwen_streaming(env, pcm):
    import websockets

    host = urllib.parse.urlparse(env["DASHSCOPE_BASE_URL"]).netloc
    task = str(uuid.uuid4())
    chunks = [pcm[i:i + STEP] for i in range(0, len(pcm), STEP)] or [b""]
    async with websockets.connect(f"wss://{host}/api-ws/v1/inference",
                                  additional_headers={"Authorization": "Bearer " + env["DASHSCOPE_API_KEY"]},
                                  max_size=None, proxy=None) as ws:
        await ws.send(json.dumps({
            "header": {"action": "run-task", "task_id": task, "streaming": "duplex"},
            "payload": {"task_group": "audio", "task": "asr", "function": "recognition", "model": QWEN_MODEL,
                        "parameters": {"format": "pcm", "sample_rate": ab.RATE}, "input": {}},
        }))
        while True:
            header = json.loads(await ws.recv())["header"]
            if header["event"] == "task-started":
                break
            if header["event"] == "task-failed":
                raise RuntimeError(f"{header.get('error_code')}: {header.get('error_message')}")

        async def sender():
            for i, c in enumerate(chunks):
                if i == len(chunks) - 1:
                    released = time.perf_counter()
                    await ws.send(c)
                    break
                await ws.send(c)
                await asyncio.sleep(ab.CHUNK_MS / 1000)
            await ws.send(json.dumps({"header": {"action": "finish-task", "task_id": task, "streaming": "duplex"},
                                      "payload": {"input": {}}}))
            return released

        send_task = asyncio.create_task(sender())
        sentences = {}
        while True:
            message = json.loads(await ws.recv())
            header = message["header"]
            if header["event"] == "result-generated":
                s = message["payload"]["output"]["sentence"]
                if s.get("heartbeat"):
                    continue
                if sentences.get(s["sentence_id"], (0, "", False))[2] and not s.get("sentence_end"):
                    continue
                sentences[s["sentence_id"]] = (s.get("begin_time", 0), s["text"], bool(s.get("sentence_end")))
            elif header["event"] == "task-finished":
                break
            elif header["event"] == "task-failed":
                raise RuntimeError(f"{header.get('error_code')}: {header.get('error_message')}")
        released = await send_task
        ordered = sorted(sentences.items(), key=lambda kv: (kv[1][0], kv[0]))
        return join_sentences([v[1] for _, v in ordered]), time.perf_counter() - released


async def doubao_streaming(env, pcm):
    text, _cost, latency = await ab.doubao_nostream(env, pcm, [])
    return text, latency


ENGINES = {"qwen": qwen_streaming, "doubao": doubao_streaming}


async def run_case(env, pcm):
    results = await asyncio.gather(*(fn(env, pcm) for fn in ENGINES.values()), return_exceptions=True)
    return dict(zip(ENGINES, results))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default=str(ROOT / "recordings" / "eval"))
    ap.add_argument("--env", default=str(ROOT.parent / ".env"))
    ap.add_argument("--only", default="")
    ap.add_argument("--note", default="", help="这次跑的说明，写进 RESULTS.md")
    args = ap.parse_args()

    cases_dir = pathlib.Path(args.cases)
    env = load_env(pathlib.Path(args.env))
    cases = sorted(p for p in cases_dir.glob("*.wav") if args.only in p.stem and p.with_suffix(".txt").exists())
    if not cases:
        sys.exit(f"{cases_dir} 里没有带 .txt 参考文本的 .wav 用例")
    commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True).stdout.strip() or "?"

    rows = []
    totals = {name: [] for name in ENGINES}
    for wav in cases:
        pcm = ab.read_pcm(wav)
        ref = reference(wav.with_suffix(".txt"))
        print(f"\n{wav.stem}  {len(pcm) / (ab.RATE * 2):.1f}s\n  参考  {ref}")
        for name, r in asyncio.run(run_case(env, pcm)).items():
            if isinstance(r, Exception):
                print(f"  {name:6}  ✗ {r}")
                rows.append((wav.stem, name, "—", "—", f"✗ {r}"))
                continue
            text, latency = r
            score = cer(ref, text)
            totals[name].append(score)
            print(f"  {name:6}  CER {score:5.1%}  {latency * 1000:4.0f} ms  {text}")
            rows.append((wav.stem, name, f"{score:.1%}", f"{latency * 1000:.0f}", text))

    results = cases_dir / "RESULTS.md"
    new = not results.exists()
    with open(results, "a") as f:
        if new:
            f.write("# Kay 识别评测\n\n由 `tools/eval.py` 追加，最新的在最下面。CER = 字错率（去标点空白后按字符），"
                    "延迟 = 松手到最终结果。参考文本在各用例的 .txt 里。\n")
        f.write(f"\n## {dt.datetime.now():%Y-%m-%d %H:%M} · eval.py @ {commit}\n\n")
        if args.note:
            f.write(args.note + "\n\n")
        avg = " · ".join(f"{n} {sum(v) / len(v):.1%}" for n, v in totals.items() if v)
        f.write(f"{len(cases)} 个用例，平均 CER：{avg}\n\n| 用例 | 引擎 | CER | 延迟 ms | 结果 |\n|---|---|---|---|---|\n")
        for case, name, score, ms, text in rows:
            f.write(f"| {case} | {name} | {score} | {ms} | {text.replace('|', '｜')} |\n")
    print(f"\n已追加到 {results}")


if __name__ == "__main__":
    main()
