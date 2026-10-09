# Kay

Hold **fn** and speak. Let go, and the text appears where your cursor is, in any app.

Kay is a small push-to-talk dictation app for macOS. It streams your voice to
[Qwen Audio 3.1 ASR](https://help.aliyun.com/zh/model-studio/qwen-audio-3-1-asr-flash-streaming)
(Alibaba Cloud) while you hold the key and pastes the finalized text when you release it.
It uses **your own API key**: there is no Kay server, and no subscription.

[中文说明](#中文说明)

## Install

1. Download `Kay-x.y.z.dmg` from [Releases](https://github.com/max1874/kay/releases) and drag Kay to Applications.
   It is signed and notarized. Requires **macOS 26** on Apple silicon. From 1.5.0 on Kay updates itself
   (Sparkle): it checks once a day, downloads in the background and installs while you're not dictating.
2. Open Kay and allow **Microphone** and **Accessibility** (to notice the key and paste for you).
3. Add an Alibaba Cloud API key in **Settings → Speech Service** (see below), then hold fn and talk.

### Getting an Alibaba Cloud key

1. Open [Alibaba Cloud Model Studio](https://bailian.console.aliyun.com/) and create an API key.
2. In **Settings → Speech Service**, enter the key and the URL for the same workspace, such as
   `https://<WorkspaceId>.cn-beijing.maas.aliyuncs.com`. Beijing and Singapore keys use different
   workspaces and endpoints. The default `https://dashscope.aliyuncs.com` is the legacy Beijing endpoint.
3. Press **Test & Save**. Kay starts a task with the same model and WebSocket as dictation, verifies
   access without sending microphone audio, then saves the key in the Keychain.

Kay uses `qwen-audio-3.1-asr-flash-streaming`. Pricing is Alibaba Cloud's and is based on input/output
Token usage; see [current rates](https://help.aliyun.com/zh/model-studio/qwen-audio-3-1-asr-flash-streaming).
Existing Doubao keys are kept separately and are never sent to Alibaba Cloud.

## How it works

- **Hold to talk.** fn by default, Right Option as an alternative. Pressing any other key while holding
  cancels, so fn and ⌥ shortcuts keep working.
- **Streaming ASR.** Audio is converted to 16 kHz / 16-bit mono in 200 ms packets. Kay buffers it until
  the task is ready, sends packets in order, then finalizes the task on release. Final sentences are
  collected by sentence ID so partial revisions never duplicate text.
- **Paste.** The text goes through the clipboard and a simulated ⌘V, and the previous clipboard is restored.
  Without Accessibility permission Kay just copies it.
- **History.** Every dictation — and the reason, when one fails — is kept on this Mac in
  `~/Library/Application Support/Kay/history.json` (last 1000). Click one to copy it again.
- **Recent audio.** The last 20 dictations' audio is kept next to it in `recent/<entry id>.wav`, so a
  misrecognition can be played back or sent again (for example with `tools/ab.py`). A dictation cut off by a
  crash or quit is recognized again at the next launch and lands in History. Deleting an entry, or Clear All,
  deletes its audio.
- **Microphone.** The microphone menu under the status line in Kay's window picks the input device; when it isn't connected, Kay records from the
  system default.

### Privacy

Your key is stored in the macOS Keychain. Audio goes directly from your Mac to the Alibaba Cloud workspace
you configure (`*.maas.aliyuncs.com` or `dashscope.aliyuncs.com`). Recent audio stays on this Mac except when
you explicitly send it again for recognition.

## Build from source

```
macOS/    the Mac app (SwiftPM; Package.swift is at the root), its resources and scripts
iOS/      an experimental iPhone app (Xcode project) — not maintained, not on the App Store
Shared/   compiled into both: the Qwen streaming protocol, audio capture, key storage, history
```

Needs Xcode 26 (macOS 26 SDK).

### About the iPhone app

`iOS/` is an experiment that stopped on purpose. It dictates from a Control (Action Button, Control Center,
Lock Screen) through an `AudioRecordingIntent`, with a Live Activity while it listens, and it works — but iOS
lets only a keyboard type into another app, and keeps the clipboard from an app in the background (tested on
iOS 27, 2026-09-30). So the text only reaches the clipboard when Kay is in front, or through a Shortcut that
copies the action's result, and every dictation ends in a manual paste. Against the built-in dictation, or a
keyboard such as Doubao's own, that was not worth it. Kept for reference; build it with Xcode 27.

```sh
make app      # build/Kay.app — signed with your Developer ID if you have one, ad hoc otherwise
make icon     # regenerate macOS/Resources/AppIcon.icns
make strings  # regenerate the .lproj tables from macOS/scripts/localize.py (English, Simplified Chinese)
```

`make release` / `make install` are the maintainer's notarize-and-publish flow and depend on private tooling
(`asc`); you don't need them to build or run Kay. `make release` notarizes a build, publishes it — the GitHub
release, then the appcast that installed copies update from — and installs it on the maintainer's Mac.

`tools/ab.py` compares Doubao and Qwen ASR on an audio file (latency, text, cost). It reads credentials from a
`.env` file in the repository root, which is git-ignored.

## License

[MIT](LICENSE)

---

## 中文说明

按住 **fn** 说话，松开后文字直接出现在光标处，任何 app 里都可以。

Kay 是一个 macOS 按住说话的听写工具：按住期间把语音实时推给阿里云的**千问语音 3.1 流式识别**，
松开后将最终文本粘贴到光标处。使用**你自己的 API Key**，没有 Kay 服务器，也没有订阅。

**安装**：从 [Releases](https://github.com/max1874/kay/releases) 下载 DMG 拖进「应用程序」（已签名公证，需要
Apple 芯片的 macOS 26）。1.5.0 起自动更新：每天检查一次，后台下载，不在听写时自动装好。首次打开允许「麦克风」和「辅助功能」，然后在「设置 → 语音服务」里填 Key。

**获取 Key**：在[阿里云百炼控制台](https://bailian.console.aliyun.com/)创建 API Key，
在 Kay 中填写 Key 和同一工作空间的地址，例如 `https://<WorkspaceId>.cn-beijing.maas.aliyuncs.com`。
点「测试并保存」后，Kay 会先验证该工作空间的千问模型访问权限，通过后才将密钥保存到钥匙串。
费用由阿里云按输入、输出 Token 收取。旧豆包 Key 独立保留，不会发给阿里云。

**快捷键**：默认 fn，可改成右 Option。按住时再按其他键会取消本次录音，所以 fn 和 ⌥ 组合键照常可用。
如果松开 fn 后弹出了表情面板，把「系统设置 → 键盘 → 按下 🌐 键时」设为「不执行任何操作」。

**隐私**：Key 只存在 macOS 钥匙串；音频从你的 Mac 直接发到阿里云，不经过其他地方。
听写历史只保存在本机，可在「设置 → 通用」里全部清除。

**iPhone 版**：`iOS/` 是一次主动叫停的实验。用操作按钮 / 控制中心触发录音、灵动岛显示状态，这些都跑通了；
但 iOS 只允许输入法往别的 app 里打字，也不允许后台 app 写剪贴板（iOS 27 实测，2026-09-30），每次都要多一步
手动粘贴，比不上系统自带的听写或豆包输入法，所以不维护、不上架，代码留作参考。
