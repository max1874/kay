# /// script
# requires-python = ">=3.11"
# ///
"""给评测用例标参考答案的本地网页：边听录音边改，保存即写进用例的 .txt。

用法:
  uv run tools/label.py                       # http://127.0.0.1:8765
  uv run tools/label.py --drafts FILE.json    # 没标过的用例先填上草稿 {"<用例名>": {"text": "...", "hint": "..."}}

只监听本机。用例目录和 eval.py 一样（kay 仓库同级的 asr-lexicon/eval/kay，--cases 另指）。页面上列出 Kay
当时的输出和 RESULTS.md 里最近一次千问、豆包不带热词的结果，方便对照。保存只改 .txt 里第一行不以 # 开头的
那一行（没有就加在注释后面），不提交；标完在 asr-lexicon 里 git commit。
"""

import argparse
import html
import json
import pathlib
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent


def repo_root() -> pathlib.Path:
    common = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True).stdout.strip()
    return pathlib.Path(common).parent if common else ROOT.parent


def read_case(txt: pathlib.Path):
    comments, reference, live = [], None, ""
    lines = txt.read_text().splitlines() if txt.exists() else []
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#"):
            comments.append(line)
            if "Kay live output" in line and i + 1 < len(lines):
                live = lines[i + 1].lstrip("# ").strip()
        elif line.strip() and reference is None:
            reference = line.strip()
    return comments, reference, live


def write_reference(txt: pathlib.Path, text: str):
    lines = txt.read_text().splitlines() if txt.exists() else []
    for i, line in enumerate(lines):
        if line.strip() and not line.lstrip().startswith("#"):
            lines[i] = text
            break
    else:
        lines.append(text)
    txt.write_text("\n".join(lines) + "\n")


def latest_outputs(results: pathlib.Path):
    """{用例: {"qwen": 文本, "doubao": 文本}}，取 RESULTS.md 里每个用例最后一次不带热词的结果。"""
    out = {}
    if not results.exists():
        return out
    for line in results.read_text().splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        # | 用例 | 引擎 | 热词 | CER | 延迟 ms | 结果 | 变化 |; older rows have no 热词 column and are skipped.
        if len(cells) == 7 and cells[1] in ("qwen", "doubao") and cells[2] == "无":
            out.setdefault(cells[0], {})[cells[1]] = cells[5]
    return out


PAGE = """<!doctype html><html lang="zh-Hans"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kay 评测标注</title>
<style>
:root{--bg:#f6f6f4;--card:#fff;--ink:#1d1d1f;--mute:#6e6e73;--line:#e3e3e0;--accent:#0a66d8;--ok:#1f8a4c;--draft:#b26b00}
@media (prefers-color-scheme:dark){:root{--bg:#161617;--card:#222224;--ink:#f2f2f2;--mute:#a1a1a6;--line:#3a3a3c;--accent:#4c9bff;--ok:#3ccf7a;--draft:#ffb340}}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}
header{position:sticky;top:0;background:var(--bg);padding:14px 16px;border-bottom:1px solid var(--line);z-index:1}
header h1{font-size:17px;margin:0} header p{margin:2px 0 0;color:var(--mute);font-size:13px}
main{max-width:860px;margin:0 auto;padding:12px 16px 80px}
.case{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:12px 0}
.top{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.name{font-weight:600}.dur{color:var(--mute);font-size:13px}
.state{margin-left:auto;font-size:12px;font-weight:600}.state.saved{color:var(--ok)}.state.draft{color:var(--draft)}
audio{width:100%;margin:8px 0 4px}
dl{margin:6px 0;display:grid;grid-template-columns:72px 1fr;gap:2px 10px;font-size:13px}dt{color:var(--mute)}dd{margin:0}
.hint{font-size:13px;color:var(--draft);margin:4px 0}
textarea{width:100%;box-sizing:border-box;font:inherit;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--ink);min-height:64px;resize:vertical}
.row{display:flex;gap:8px;margin-top:8px;align-items:center}button{font:inherit;padding:6px 14px;border-radius:8px;border:0;background:var(--accent);color:#fff;cursor:pointer}
.small{color:var(--mute);font-size:12px}
</style>
<header><h1>Kay 评测标注</h1><p id="progress"></p><p>听录音，把框里改成你实际说的话，⌘↩ 或「保存」。保存直接写进用例的 .txt。</p></header>
<main id="cases"></main>
<script>
const cases = __CASES__;
const root = document.getElementById('cases');
function progress(){const n=cases.filter(c=>c.saved).length;document.getElementById('progress').textContent=`已标 ${n} / ${cases.length}`;}
for (const c of cases) {
  const el = document.createElement('section'); el.className='case';
  el.innerHTML = `<div class="top"><span class="name"></span><span class="dur"></span><span class="state"></span></div>
    <audio controls preload="none"></audio>
    <dl><dt>Kay 当时</dt><dd class="live"></dd><dt>千问</dt><dd class="qwen"></dd><dt>豆包</dt><dd class="doubao"></dd></dl>
    <div class="hint"></div><textarea></textarea>
    <div class="row"><button>保存</button><span class="small msg"></span></div>`;
  el.querySelector('.name').textContent=c.name; el.querySelector('.dur').textContent=c.seconds.toFixed(1)+' 秒';
  el.querySelector('audio').src='/audio/'+encodeURIComponent(c.name)+'.wav';
  el.querySelector('.live').textContent=c.live||'—'; el.querySelector('.qwen').textContent=c.qwen||'—'; el.querySelector('.doubao').textContent=c.doubao||'—';
  el.querySelector('.hint').textContent=c.hint?('拿不准：'+c.hint):'';
  const ta=el.querySelector('textarea'); ta.value=c.reference||c.draft||c.doubao||c.live||'';
  const state=el.querySelector('.state'), msg=el.querySelector('.msg');
  const show=()=>{state.textContent=c.saved?'已保存':(c.draft?'草稿':'未标');state.className='state '+(c.saved?'saved':'draft');};
  async function save(){const text=ta.value.trim(); if(!text) return;
    const r=await fetch('/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:c.name,text})});
    if(r.ok){c.saved=true;c.reference=text;msg.textContent='写入 '+c.name+'.txt';show();progress();} else msg.textContent='保存失败：'+await r.text();}
  el.querySelector('button').onclick=save;
  ta.addEventListener('keydown',e=>{if(e.key==='Enter'&&(e.metaKey||e.ctrlKey)){e.preventDefault();save();}});
  ta.addEventListener('input',()=>{if(c.saved&&ta.value.trim()!==c.reference){c.saved=false;show();progress();}});
  show(); root.appendChild(el);
}
progress();
</script></html>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default="")
    ap.add_argument("--drafts", default="")
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    cases_dir = pathlib.Path(args.cases or repo_root().parent / "asr-lexicon" / "eval" / "kay").resolve()
    drafts = json.loads(pathlib.Path(args.drafts).read_text()) if args.drafts else {}

    def cases():
        outputs = latest_outputs(cases_dir / "RESULTS.md")
        items = []
        for wav in sorted(cases_dir.glob("*.wav")):
            _, reference, live = read_case(wav.with_suffix(".txt"))
            d = drafts.get(wav.stem, {})
            items.append({"name": wav.stem, "seconds": max(wav.stat().st_size - 44, 0) / 32000,
                          "live": live, "reference": reference, "saved": reference is not None,
                          "draft": d.get("text"), "hint": d.get("hint"),
                          **outputs.get(wav.stem, {})})
        return items

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, body, kind="text/plain; charset=utf-8"):
            data = body if isinstance(body, bytes) else body.encode()
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/":
                payload = json.dumps(cases(), ensure_ascii=False).replace("</", "<\\/")
                return self.send(200, PAGE.replace("__CASES__", payload), "text/html; charset=utf-8")
            m = re.fullmatch(r"/audio/([\w-]+)\.wav", self.path)
            if m and (cases_dir / f"{m[1]}.wav").is_file():
                return self.send(200, (cases_dir / f"{m[1]}.wav").read_bytes(), "audio/wav")
            self.send(404, "not found")

        def do_POST(self):
            if self.path != "/save":
                return self.send(404, "not found")
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            name, text = str(body.get("name", "")), " ".join(str(body.get("text", "")).split())
            if not re.fullmatch(r"[\w-]+", name) or not (cases_dir / f"{name}.wav").is_file() or not text or text.startswith("#"):
                return self.send(400, "bad request")
            write_reference(cases_dir / f"{name}.txt", text)
            print(f"saved {name}: {text}", flush=True)
            self.send(200, "ok")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"http://127.0.0.1:{args.port}  ({cases_dir})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
