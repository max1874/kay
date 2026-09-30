# Kay

macOS 菜单栏听写工具：按住**右 Option** 说话，松开后文字直接出现在当前光标处。

- 语音识别：豆包流式语音识别 2.0，一句话模式（`bigmodel_nostream`）。说话期间按 200ms 分包实时推流，松开后只等最后一包，约 0.3 秒出字。
- 插入方式：剪贴板 + 模拟 ⌘V，之后恢复原剪贴板。
- 需要的权限：麦克风、辅助功能（监听右 Option、模拟粘贴）。
- API Key：首次启动时填写豆包语音（火山引擎新版控制台）的 API Key，保存在 `~/Library/Application Support/Kay/config.json`（权限 600）。

## 发布与安装

签名、公证、DMG 由 `~/Projects/Repo/apple-developer` 的 `asc notarize kay` 负责。

```sh
make release   # 公证 + 发 GitHub Release（scripts/publish.sh --dry-run 只检查不公证）
make install   # 把发布的 DMG 装进 /Applications，本机用和测都用这一份
```

`make app` 只是流水线的输入，不在本机日常运行。

## tools/ab.py

豆包 / 千问 ASR 的 A/B 对比脚本（延迟、文本、费用）。凭据读仓库根目录的 `.env`（不进 git）。

```sh
uv run tools/ab.py path/to/audio.m4a
```
