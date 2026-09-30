# Kay

macOS 听写 app：按住**右 Option** 说话，松开后文字直接出现在当前光标处。

- 完整窗口 app（Dock + 主窗口 + 标准菜单），关掉窗口不退出，听写一直可用；菜单栏图标可在「通用」里关掉。
  - **首页**：权限 / 语音服务检查清单、用量统计（本机统计的次数、字数、音频时长）、最近记录。
  - **历史**：全部听写记录，可搜索、复制、删除；失败的识别也会记下原因。存于 `~/Library/Application Support/Kay/history.json`（600，最多 1000 条）。
  - **语音服务**：BYOK。粘贴火山引擎 API Key →「测试并保存」：先用同一个 WebSocket 握手验证（401 = Key 无效，403 = 未开通该资源），通过后才写入钥匙串并读回确认。可切换小时版 / 并发版资源。
  - **通用**：快捷键说明、权限、登录时打开、菜单栏图标。
- 语音识别：豆包流式语音识别 2.0，一句话模式（`bigmodel_nostream`）。说话期间按 200ms 分包实时推流，松开后只等最后一包，约 0.3 秒出字。
- 插入方式：剪贴板 + 模拟 ⌘V，之后恢复原剪贴板；没有辅助功能权限时只复制。
- 需要的权限：麦克风、辅助功能（监听右 Option、模拟粘贴）。
- 界面语言：英文 / 简体中文，跟随系统。文案表在 `scripts/localize.py`，改完运行它重新生成 `Resources/*.lproj`。
- 1.0.0 存在 `config.json` 里的 Key 会在首次启动时迁移到钥匙串并删除该文件。

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
