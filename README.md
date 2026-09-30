# Kay

macOS 听写 app：按住 **fn（🌐）** 说话，松开后文字直接出现在当前光标处。快捷键可在设置里改成右 Option。

- 完整的 macOS 26 app（Liquid Glass），Dock + 主窗口 + 设置窗口（⌘,）+ 可选菜单栏图标；关掉窗口不退出，听写一直可用。
  - **主窗口**：单栏。顶部是快捷键和状态（还没设置好时列出麦克风、辅助功能、语音服务三项）与本机用量统计；下面是按天分组的听写卡片，点一下即拷贝，悬停可删除，失败的记录写明原因；工具栏可搜索。
  - **设置 · 语音服务**：BYOK。粘贴火山引擎 API Key →「测试并保存」：先用同一个 WebSocket 握手验证（401 = Key 无效，403 = 未开通该资源），通过后才写入钥匙串并读回确认；替换用的新 Key 测试失败时不影响已保存的 Key。可切换小时版 / 并发版资源。
  - **设置 · 通用**：快捷键说明、权限、登录时打开、菜单栏图标。
  - **HUD**：屏幕底部的玻璃胶囊，录音时显示电平和计时，识别时显示进度。
- 历史存于 `~/Library/Application Support/Kay/history.json`（600，最多 1000 条），可在设置 → 通用里全部清除。
- 语音识别：豆包流式语音识别 2.0，一句话模式（`bigmodel_nostream`）。说话期间按 200ms 分包实时推流，松开后只等最后一包，约 0.3 秒出字。
- 插入方式：剪贴板 + 模拟 ⌘V，之后恢复原剪贴板；没有辅助功能权限时只复制。
- 需要的权限：麦克风、辅助功能（监听快捷键、模拟粘贴）。fn 是按住使用，一般不会触发 macOS 自己的 🌐 键功能；若松开后仍弹出表情面板，可把「系统设置 → 键盘 → 按下 🌐 键时」设为「不执行任何操作」（设置页有提示）。
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
