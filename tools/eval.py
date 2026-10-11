# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets>=14", "sounddevice>=0.5"]
# ///
"""Kay 的识别评测：把评测录音按 Kay 自己的协议和参数送给每个 provider，算字错率，结果追加到 RESULTS.md。

用法:
  uv run tools/eval.py                          # 跑全部用例，不带热词
  uv run tools/eval.py --hotwords FILE          # 带热词名单跑
  uv run tools/eval.py --compare FILE           # 每条都不带 / 带名单各跑一遍：认回了哪些名单词、拉进了哪些没说的
  uv run tools/eval.py --only 2026-10-11        # 只跑文件名含这个串的用例

用例和结果在私有仓库 asr-lexicon 的 eval/kay/（默认找 kay 仓库同级的 asr-lexicon，worktree 里也一样；
--cases 另指）。凭证读 kay 仓库根目录的 .env（--env 另指）。用例: <name>.wav（16 kHz 单声道，从
~/Library/Application Support/Kay/recent/ 拷）加同名 <name>.txt；.txt 里第一行不以 # 开头的是参考文本，
没有就只出识别结果、不算 CER。

热词名单的格式和 Kay 读的 vocabulary.txt 一样（Shared/Vocabulary.swift）：一行一个词，# 之后是注释，
行首 ! 是必拉。千问: ! 的前 50 个权重 50，其余 5，最多 2000 个；豆包: 全部放进 corpus.context 的 hotwords。

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
QWEN_MAX_WORDS, QWEN_MAX_STRONG, QWEN_STRONG, QWEN_WEIGHT = 2000, 50, 50, 5


def repo_root() -> pathlib.Path:
    """The main checkout, also from a worktree: where .env and the sibling asr-lexicon are."""
    common = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True).stdout.strip()
    return pathlib.Path(common).parent if common else ROOT.parent


def load_env(path: pathlib.Path):
    env = {}
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def load_hotwords(path: pathlib.Path):
    """[(词, 是否必拉)]，去重保序。"""
    seen, words = set(), []
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        strong = line.startswith("!")
        word = line.lstrip("!").strip()
        if word and word not in seen:
            seen.add(word)
            words.append((word, strong))
    return words


def qwen_vocabulary(hotwords):
    strong = [w for w, s in hotwords if s][:QWEN_MAX_STRONG]
    rest = [w for w, _ in hotwords if w not in strong]
    vocabulary = {w: QWEN_STRONG for w in strong}
    vocabulary.update({w: QWEN_WEIGHT for w in rest})
    return dict(list(vocabulary.items())[:QWEN_MAX_WORDS])


def reference(txt: pathlib.Path):
    for line in txt.read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            return line.strip()
    return None


def mentions(text: str, hotwords):
    t = normalize(text)
    return {w for w, _ in hotwords if normalize(w) in t}


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


async def qwen_streaming(env, pcm, hotwords):
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
                        "parameters": {"format": "pcm", "sample_rate": ab.RATE,
                                       **({"vocabulary": qwen_vocabulary(hotwords)} if hotwords else {})},
                        "input": {}},
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


async def doubao_streaming(env, pcm, hotwords):
    text, _cost, latency = await ab.doubao_nostream(env, pcm, [w for w, _ in hotwords])
    return text, latency


ENGINES = {"qwen": qwen_streaming, "doubao": doubao_streaming}


async def run_case(env, pcm, lists):
    """{(引擎, 名单名): 结果}，全部并发。"""
    jobs = {(engine, name): fn(env, pcm, words) for engine, fn in ENGINES.items() for name, words in lists.items()}
    results = await asyncio.gather(*jobs.values(), return_exceptions=True)
    return dict(zip(jobs, results))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default="")
    ap.add_argument("--env", default="")
    ap.add_argument("--only", default="")
    ap.add_argument("--hotwords", default="", help="带这份热词名单跑")
    ap.add_argument("--compare", default="", help="不带 / 带这份名单各跑一遍")
    ap.add_argument("--note", default="", help="这次跑的说明，写进 RESULTS.md")
    args = ap.parse_args()

    root = repo_root()
    cases_dir = pathlib.Path(args.cases or root.parent / "asr-lexicon" / "eval" / "kay")
    env = load_env(pathlib.Path(args.env or root / ".env"))
    list_file = args.compare or args.hotwords
    hotwords = load_hotwords(pathlib.Path(list_file)) if list_file else []
    lists = {"无": [], "名单": hotwords} if args.compare else {("名单" if hotwords else "无"): hotwords}
    cases = sorted(p for p in cases_dir.glob("*.wav") if args.only in p.stem)
    if not cases:
        sys.exit(f"{cases_dir} 里没有 .wav 用例")
    commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True).stdout.strip() or "?"

    rows, totals, gained, pulled = [], {}, [], []
    for wav in cases:
        pcm = ab.read_pcm(wav)
        txt = wav.with_suffix(".txt")
        ref = reference(txt) if txt.exists() else None
        print(f"\n{wav.stem}  {len(pcm) / (ab.RATE * 2):.1f}s" + (f"\n  参考  {ref}" if ref else "  （无参考）"))
        results = asyncio.run(run_case(env, pcm, lists))
        for (engine, name), r in results.items():
            if isinstance(r, Exception):
                print(f"  {engine:6} {name}  ✗ {r}")
                rows.append((wav.stem, engine, name, "—", "—", f"✗ {r}", ""))
                continue
            text, latency = r
            score = cer(ref, text) if ref else None
            if score is not None:
                totals.setdefault((engine, name), []).append(score)
            note = ""
            if args.compare and name == "名单" and not isinstance(results[(engine, "无")], Exception):
                before = mentions(results[(engine, "无")][0], hotwords)
                after = mentions(text, hotwords)
                said = mentions(ref, hotwords) if ref else None
                new = after - before
                if said is None:
                    note = f"新出现：{'、'.join(sorted(new))}" if new else ""
                else:
                    got, bad = new & said, new - said
                    gained += [(wav.stem, engine, w) for w in got]
                    pulled += [(wav.stem, engine, w) for w in bad]
                    note = "；".join(x for x in (f"认回：{'、'.join(sorted(got))}" if got else "",
                                                f"拉偏：{'、'.join(sorted(bad))}" if bad else "") if x)
                if new and said is None:
                    pulled += [(wav.stem, engine, f"{w}（无参考，待核）") for w in new]
            shown = f"CER {score:5.1%}  " if score is not None else ""
            print(f"  {engine:6} {name}  {shown}{latency * 1000:4.0f} ms  {text}" + (f"   ← {note}" if note else ""))
            rows.append((wav.stem, engine, name, f"{score:.1%}" if score is not None else "—",
                         f"{latency * 1000:.0f}", text, note))

    results_md = cases_dir / "RESULTS.md"
    with open(results_md, "a") as f:
        f.write(f"\n## {dt.datetime.now():%Y-%m-%d %H:%M} · eval.py @ {commit}\n\n")
        if args.note:
            f.write(args.note + "\n\n")
        if hotwords:
            mode = "对照（不带 / 带）" if args.compare else "带"
            f.write(f"热词：{pathlib.Path(list_file).name}，{len(hotwords)} 个（必拉 {sum(s for _, s in hotwords)}），{mode}\n\n")
        else:
            f.write("热词：无\n\n")
        avg = " · ".join(f"{e}/{n} {sum(v) / len(v):.1%}（{len(v)} 条）" for (e, n), v in totals.items())
        f.write(f"{len(cases)} 个用例" + (f"，有参考的平均 CER：{avg}" if avg else "") + "\n\n")
        if args.compare:
            f.write(f"认回 {len(gained)} 处，拉偏或待核 {len(pulled)} 处" +
                    ("：" + "；".join(f"{c} {e} {w}" for c, e, w in pulled) if pulled else "") + "\n\n")
        f.write("| 用例 | 引擎 | 热词 | CER | 延迟 ms | 结果 | 变化 |\n|---|---|---|---|---|---|---|\n")
        for case, engine, name, score, ms, text, note in rows:
            f.write(f"| {case} | {engine} | {name} | {score} | {ms} | {text.replace('|', '｜')} | {note} |\n")
    print(f"\n认回 {len(gained)} 处，拉偏或待核 {len(pulled)} 处\n已追加到 {results_md}")


if __name__ == "__main__":
    main()
