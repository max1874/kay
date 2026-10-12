# Kay

Hold **fn** and speak. Let go, and the text appears where your cursor is, in any app.

Kay is a small push-to-talk dictation app for macOS. It streams your voice to
[Qwen Audio 3.1 ASR](https://help.aliyun.com/zh/model-studio/qwen-audio-3-1-asr-flash-streaming)
(Alibaba Cloud) or Doubao Streaming ASR 2.0 (Volcengine), whichever you pick, while you hold the key and
pastes the finalized text when you release it. It uses **your own API key**: there is no Kay server, and no
subscription.

[中文说明](#中文说明)

## Install

1. Download `Kay-x.y.z.dmg` from [Releases](https://github.com/max1874/kay/releases) and drag Kay to Applications.
   It is signed and notarized. Requires **macOS 26** on Apple silicon. From 1.5.0 on Kay updates itself
   (Sparkle): it checks once a day, downloads in the background and installs while you're not dictating.
2. Open Kay and allow **Microphone** and **Accessibility** (to notice the key and paste for you).
3. In **Settings → Speech Service**, pick a service under **Dictate With** and add its API key (see below),
   then hold fn and talk.

### Getting an Alibaba Cloud key

1. Open [Alibaba Cloud Model Studio](https://bailian.console.aliyun.com/) and create an API key.
2. In **Settings → Speech Service**, enter the key and the URL for the same workspace, such as
   `https://<WorkspaceId>.cn-beijing.maas.aliyuncs.com`. Beijing and Singapore keys use different
   workspaces and endpoints. The default `https://dashscope.aliyuncs.com` is the legacy Beijing endpoint.
3. Press **Test & Save**. Kay starts a task with the same model and WebSocket as dictation, verifies
   access without sending microphone audio, then saves the key in the Keychain.

Kay uses `qwen-audio-3.1-asr-flash-streaming`. Pricing is Alibaba Cloud's and is based on input/output
Token usage; see [current rates](https://help.aliyun.com/zh/model-studio/qwen-audio-3-1-asr-flash-streaming).

### Getting a Volcengine (Doubao) key

1. In the [Volcengine console](https://console.volcengine.com/speech/new/setting/apikeys) (new console), enable
   Doubao Streaming ASR 2.0 and create an API key.
2. In **Settings → Speech Service**, pick **Volcengine Doubao ASR**, enter the key and choose the resource you
   bought (hourly or concurrent), then press **Test & Save**. Kay opens the dictation WebSocket to check it.

### Switching

Each service keeps its own key in the Keychain; a key is only ever sent to its own service. Switch with
**Dictate With** in Settings or the menu next to the microphone menu in Kay's window; the next press uses the
new one. A service picked before it has a key becomes the one Kay dictates with once its key passes the test.
Each dictation in History records which service recognized it (`engine`).

### Eval

`tools/eval.py` sends eval recordings (kept privately, not in this repository) through each service the way Kay
does and reports the character error rate against a reference; `tools/label.py` serves a local page for writing
each recording's reference while listening to it. On 22 of Max's recordings (2026-10-11, three runs each) Doubao
averaged 5.6% and Qwen 14.3%. Kay sends no hot words: a list tried in 1.7.1 recovered a few names but pulled
unrelated speech towards its terms, and was removed in 1.8.0. Each dictation in History also records the
microphone it came from (`microphone`).

## How it works

- **Hold to talk.** fn by default, Right Option as an alternative. Pressing any other key while holding
  cancels, so fn and ⌥ shortcuts keep working.
- **Streaming ASR.** Audio is converted to 16 kHz / 16-bit mono in 200 ms packets. Kay buffers it until
  the task is ready, sends packets in order, then finalizes the task on release. Final sentences are
  collected by sentence ID so partial revisions never duplicate text.
- **Paste.** The text goes through the clipboard and a simulated ⌘V, and the previous clipboard is restored. With
  **Settings → General → Show in Clipboard History** off, the text is marked transient (nspasteboard.org) so
  clipboard history apps such as Raycast leave it out; the restored clipboard is always marked, since it is not a new copy.
  Without Accessibility permission Kay just copies it.
- **Correction.** Before pasting, DeepSeek V4.1 Flash (your own key, **Settings → Correction**) fixes words the
  speech service misheard, such as product names, without rewording; on by default, and a no-op until a key is
  added. On 22 of Max's dictations (2026-10-12) it took Doubao from 5.5% to 3.7–4.8% CER without changing a correct
  word into a wrong one; Qwen models with the same prompt made things worse. It adds about half a second (median
  0.6 s). Kay pastes what it heard when the whole request takes over 3 s, fails, or adds text before or after what was
  said, rewrites or drops more than a little of it, instead of replacing words in place (a reply rather than a
  correction), and for dictations under 4 words or characters. A short dictation replaced by an English word of
  about its length ("Done") still gets through: by counting it looks like a name fix. History
  keeps the recognizer's text in `heard` when correction changed it.
- **History.** Every dictation — and the reason, when one fails — is kept on this Mac in
  `~/Library/Application Support/Kay/history.json` (last 1000). Click one to copy it again.
- **Recent audio.** The last 20 dictations' audio is kept next to it in `recent/<entry id>.wav`, so a
  misrecognition can be played back or sent again (for example with `tools/ab.py`). A dictation cut off by a
  crash or quit is recognized again at the next launch and lands in History. Deleting an entry, or Clear All,
  deletes its audio.
- **Microphone.** The microphone menu under the status line in Kay's window picks the input device; when it isn't connected, Kay records from the
  system default. If that microphone doesn't start within 2 seconds, Kay falls back to the Mac's built-in one.
- **Logs.** `~/Library/Logs/Kay/kay.log` (rotated, about 8 MB in all) records each dictation's microphones,
  timings and outcome, never its text. If Kay's main thread stops answering during a dictation, a snapshot of
  every thread and the last minutes of the system log goes to `~/Library/Logs/Kay/hangs/<time>/`.

### Privacy

Your keys are stored in the macOS Keychain. Audio goes directly from your Mac to the service you picked:
the Alibaba Cloud workspace you configure (`*.maas.aliyuncs.com` or `dashscope.aliyuncs.com`) or Volcengine
(`openspeech.bytedance.com`). Recent audio stays on this Mac except when
you explicitly send it again for recognition. With a DeepSeek key added, the recognized text (not the audio) goes
to `api.deepseek.com` for correction.

## Build from source

```
macOS/    the Mac app (SwiftPM; Package.swift is at the root), its resources and scripts
iOS/      an experimental iPhone app (Xcode project) — not maintained, not on the App Store
Shared/   compiled into both: the Qwen and Doubao streaming protocols, audio capture, key storage, history
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

Kay 是一个 macOS 按住说话的听写工具：按住期间把语音实时推给阿里云的**千问语音 3.1 流式识别**或火山引擎的
**豆包流式语音识别 2.0**（二选一），松开后将最终文本粘贴到光标处。使用**你自己的 API Key**，没有 Kay 服务器，也没有订阅。

**安装**：从 [Releases](https://github.com/max1874/kay/releases) 下载 DMG 拖进「应用程序」（已签名公证，需要
Apple 芯片的 macOS 26）。1.5.0 起自动更新：每天检查一次，后台下载，不在听写时自动装好。首次打开允许「麦克风」和「辅助功能」，然后在「设置 → 语音服务」里填 Key。

**获取 Key**：在[阿里云百炼控制台](https://bailian.console.aliyun.com/)创建 API Key，
在 Kay 中填写 Key 和同一工作空间的地址，例如 `https://<WorkspaceId>.cn-beijing.maas.aliyuncs.com`。
点「测试并保存」后，Kay 会先验证该工作空间的千问模型访问权限，通过后才将密钥保存到钥匙串。
费用由阿里云按输入、输出 Token 收取。

**切换服务**：「设置 → 语音服务 → 听写使用」或主窗口麦克风菜单旁的菜单。每个服务的 Key 各自存在钥匙串里，
只发给它自己的服务。总被听错的专名（如 Raycast、Cursor）写进「语音服务 → 词汇表」，一行一个，行首加 `!` 的会被强力纠正。豆包 Key 在[火山引擎控制台](https://console.volcengine.com/speech/new/setting/apikeys)（新版）创建，
填好后选资源类型（小时版或并发版）再测试并保存。

**快捷键**：默认 fn，可改成右 Option。按住时再按其他键会取消本次录音，所以 fn 和 ⌥ 组合键照常可用。
如果松开 fn 后弹出了表情面板，把「系统设置 → 键盘 → 按下 🌐 键时」设为「不执行任何操作」。

**隐私**：Key 只存在 macOS 钥匙串；音频从你的 Mac 直接发到你选的服务（阿里云或火山引擎），不经过其他地方。填了 DeepSeek Key 时，识别出的文字（不是音频）会发给 DeepSeek 纠错（「设置 → 纠错」，默认开启）。
听写历史只保存在本机，可在「设置 → 通用」里全部清除。

**iPhone 版**：`iOS/` 是一次主动叫停的实验。用操作按钮 / 控制中心触发录音、灵动岛显示状态，这些都跑通了；
但 iOS 只允许输入法往别的 app 里打字，也不允许后台 app 写剪贴板（iOS 27 实测，2026-09-30），每次都要多一步
手动粘贴，比不上系统自带的听写或豆包输入法，所以不维护、不上架，代码留作参考。
