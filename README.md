# Kay

Hold **fn** and speak. Let go, and the text appears where your cursor is, in any app.

Kay is a small push-to-talk dictation app for macOS. It streams your voice to
[Doubao Streaming ASR 2.0](https://www.volcengine.com/product/voice-tech) (Volcengine) while you hold the key,
so the text is usually there 0.3–0.7 s after you let go. It uses **your own API key**: there is no Kay
server, and no subscription.

[中文说明](#中文说明)

## Install

1. Download `Kay-x.y.z.dmg` from [Releases](https://github.com/max1874/kay/releases) and drag Kay to Applications.
   It is signed and notarized. Requires **macOS 26** on Apple silicon.
2. Open Kay and allow **Microphone** and **Accessibility** (to notice the key and paste for you).
3. Add a Volcengine API key in **Settings → Speech Service** (see below), then hold fn and talk.

### Getting a Volcengine key

1. Sign in to the [Volcengine console](https://console.volcengine.com/speech/new/overview) and enable
   **Doubao Streaming ASR 2.0** (豆包流式语音识别 2.0) — hourly or concurrent billing.
2. Create a key under **API Key** in the new speech console.
3. Paste it into Kay and press **Test & Save**. Kay opens the same WebSocket it dictates with and checks the
   handshake before it stores anything: 401 means the key is wrong, 403 means the service isn't enabled for it.

Pricing is Volcengine's: at the time of writing about ¥1 per hour of audio, with 20 free hours. Kay only
sends audio while you hold the key.

## How it works

- **Hold to talk.** fn by default, Right Option as an alternative. Pressing any other key while holding
  cancels, so fn and ⌥ shortcuts keep working.
- **Streaming, sentence mode** (`bigmodel_nostream`). Audio is converted to 16 kHz / 16-bit mono and sent in
  200 ms packets as you speak; on release only the last packet is left to recognize.
- **Paste.** The text goes through the clipboard and a simulated ⌘V, and the previous clipboard is restored.
  Without Accessibility permission Kay just copies it.
- **History.** Every dictation — and the reason, when one fails — is kept on this Mac in
  `~/Library/Application Support/Kay/history.json` (last 1000). Click one to copy it again.

### Privacy

Your key is stored in the macOS Keychain. Audio goes directly from your Mac to Volcengine's endpoint
(`openspeech.bytedance.com`). Nothing else is sent anywhere.

## Build from source

Needs Xcode 26 (macOS 26 SDK).

```sh
make app      # build/Kay.app — signed with your Developer ID if you have one, ad hoc otherwise
make icon     # regenerate Resources/AppIcon.icns
```

UI strings live in one table, `scripts/localize.py` (English and Simplified Chinese). Run it after changing
a string to regenerate `Resources/*.lproj`.

`make release` / `make install` are the maintainer's notarize-and-publish flow and depend on private
tooling (`asc`); you don't need them to build or run Kay.

`tools/ab.py` compares Doubao and Qwen ASR on an audio file (latency, text, cost). It reads credentials from a
`.env` file in the repository root, which is git-ignored.

## License

[MIT](LICENSE)

---

## 中文说明

按住 **fn** 说话，松开后文字直接出现在光标处，任何 app 里都可以。

Kay 是一个 macOS 按住说话的听写工具：按住期间把语音实时推给火山引擎的**豆包流式语音识别 2.0**，
松开后通常 0.3–0.7 秒出字。使用**你自己的 API Key**，没有 Kay 服务器，也没有订阅。

**安装**：从 [Releases](https://github.com/max1874/kay/releases) 下载 DMG 拖进「应用程序」（已签名公证，需要
Apple 芯片的 macOS 26）。首次打开允许「麦克风」和「辅助功能」，然后在「设置 → 语音服务」里填 Key。

**获取 Key**：在[火山引擎控制台](https://console.volcengine.com/speech/new/overview)开通「豆包流式语音识别 2.0」
（小时版或并发版），在新版语音控制台的「API Key」里创建一个，粘贴到 Kay 点「测试并保存」。
Kay 会先用听写用的同一个 WebSocket 做握手验证，通过后才存进钥匙串。费用由火山引擎收取，写这份说明时
约 1 元/小时音频，有 20 小时免费额度。

**快捷键**：默认 fn，可改成右 Option。按住时再按其他键会取消本次录音，所以 fn 和 ⌥ 组合键照常可用。
如果松开 fn 后弹出了表情面板，把「系统设置 → 键盘 → 按下 🌐 键时」设为「不执行任何操作」。

**隐私**：Key 只存在 macOS 钥匙串；音频从你的 Mac 直接发到火山引擎，不经过其他地方。
听写历史只保存在本机，可在「设置 → 通用」里全部清除。
