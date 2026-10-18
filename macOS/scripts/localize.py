#!/usr/bin/env python3
"""Emits macOS/Resources/{en,zh-Hans}.lproj/Localizable.strings (and zh-Hans InfoPlist.strings) from one table.

Run it by hand after changing a user-visible string; the .strings files are committed, so a
build never needs Python. English is the key, so en.lproj is key == value.
Interpolations follow Swift's format keys: Int -> %lld, String -> %@.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

GROUPS = [
    ("Shortcut", [
        ("Right Option", "右 Option"),
        ("Hold %@ to Dictate", "按住 %@ 开始听写"),
        ("Lets Kay notice the dictation key and paste the text for you.", "用来识别听写快捷键，并把文字粘贴到光标处。"),
        ("fn (🌐)", "fn（🌐）"),
        ("If the emoji picker or another input source shows up after you let go of fn, set “Press 🌐 key to” to “Do Nothing”.",
         "如果松开 fn 后弹出了表情面板或切换了输入法，把「按下 🌐 键时」设为「不执行任何操作」。"),
        ("Keyboard Settings…", "键盘设置…"),
        ("Pressing any other key while you hold it cancels the recording, so shortcuts that use the same key keep working.",
         "按住时再按其他键会取消本次录音，所以用到这个键的组合键照常可用。"),
    ]),
    ("App and menu bar", [
        ("Open Kay", "打开 Kay"),
        ("Settings…", "设置…"),
        ("Quit Kay", "退出 Kay"),
    ]),
    ("Main window", [
        ("Settings", "设置"),
        ("Speech service, shortcut and permissions", "语音服务、快捷键和权限"),
        ("Search Dictations", "搜索听写"),
        ("No dictations yet. Hold %@ and say something.", "还没有听写记录。按住 %@ 说句话试试。"),
        ("Listening…", "正在听…"),
        ("Clear All…", "全部清除…"),
        ("Delete all dictation history?", "删除全部听写历史？"),
        ("Delete All", "全部删除"),
        ("This can't be undone.", "此操作无法撤销。"),
        ("Copy", "拷贝"),
        ("Copied", "已拷贝"),
        ("Delete", "删除"),
        ("Today", "今天"),
        ("Yesterday", "昨天"),
    ]),
    ("Home", [
        ("Finish Setting Up Kay", "完成 Kay 的设置"),
        ("Speak while you hold it. Let go, and the text appears where your cursor is, in any app.",
         "按住时说话，松开后文字会出现在光标处，任何 app 里都可以。"),
        ("Microphone", "麦克风"),
        ("Kay records only while you hold the key.", "只在你按住快捷键时录音。"),
        ("Allow", "允许"),
        ("Accessibility", "辅助功能"),
        ("Open System Settings", "打开系统设置"),
        ("Speech Service", "语音服务"),
        ("Add API Key", "填写 API Key"),
        ("Dictations Today", "今日听写"),
        ("Characters", "累计字数"),
        ("Audio Sent", "累计音频"),
        ("Alibaba Cloud Console", "阿里云控制台"),
        ("Volcengine Console", "火山引擎控制台"),
        ("Speech Service Settings…", "语音服务设置…"),
        ("The speech service Kay dictates with. Each one uses its own key.", "Kay 听写用的语音服务，每个服务用各自的 Key。"),
    ]),
    ("Live", [
        ("Qwen Audio 3.1 · streaming", "千问语音 3.1 · 流式识别"),
        ("Streaming ASR 2.0 · sentence mode", "流式语音识别 2.0 · 一句话模式"),
        ("Qwen", "千问"),
        ("Doubao", "豆包"),
        ("Volcengine Doubao ASR", "火山引擎豆包语音识别"),
        ("Recognizing…", "识别中…"),
    ]),
    ("Settings", [
        ("General", "通用"),
        ("Shortcut", "快捷键"),
        ("Hold to talk", "按住说话"),
        ("Right Option ⌥", "右 Option ⌥"),
        ("Permissions", "权限"),
        ("Granted", "已授权"),
        ("App", "应用"),
        ("Open at Login", "登录时打开"),
        ("Show in Menu Bar", "在菜单栏显示"),
        ("Show in Dock", "在程序坞显示"),
        ("Check for Updates…", "检查更新…"),
        ("Without a Dock icon Kay opens straight into the background at launch. Open Kay again from Spotlight or Applications to bring this window back.",
         "不显示程序坞图标时，Kay 启动后直接在后台运行。要打开这个窗口，从聚焦搜索或「应用程序」里再打开一次 Kay。"),
        ("History", "历史记录"),
        ("Show in Finder", "在访达中显示"),
        ("Version", "版本"),
        ("Workspace URL", "工作空间地址"),
        ("Dictate With", "听写使用"),
        ("Kay keeps dictating with %@ until this key passes the test.", "这个 Key 测试通过前，Kay 继续用%@听写。"),
        ("Kay uses your own account with each service. Audio goes straight from this Mac to the one you choose, keys stay in the macOS Keychain, and each service bills you at its standard rates. You can also switch from the menu under the status line in Kay's window.",
         "Kay 在每个服务上使用你自己的账号。音频从这台 Mac 直接发送到你选的服务，密钥保存在 macOS 钥匙串中，费用由各服务按标准价格收取。也可以在 Kay 主窗口状态栏下方的菜单里切换。"),
        ("API Key", "API Key"),
        ("Alibaba Cloud Model Studio → API Key. Use the key and URL for the same workspace.", "阿里云百炼 → API Key。请使用同一工作空间的密钥和地址。"),
        ("Volcengine console → Doubao Speech → API Key (new console).", "火山引擎控制台 → 豆包语音 → API Key（新版控制台）。"),
        ("Resource", "资源类型"),
        ("Hourly", "小时版"),
        ("Concurrent", "并发版"),
        ("Test Again", "重新测试"),
        ("Test & Save", "测试并保存"),
        ("Get an API Key ↗", "获取 API Key ↗"),
        ("Remove Key…", "移除 Key…"),
        ("Alibaba Qwen ASR", "阿里千问语音识别"),
        ("Remove this key from Kay?", "从 Kay 移除这个 Key？"),
        ("Remove", "移除"),
        ("It stays valid in Alibaba Cloud. If it was exposed, revoke it in the console.",
         "它在阿里云中仍然有效。如果已经泄露，请到控制台吊销。"),
        ("It stays valid in Volcengine. If it was exposed, revoke it in the console.",
         "它在火山引擎中仍然有效。如果已经泄露，请到控制台吊销。"),
        ("Saved (%@). Paste a new key to replace it.", "已保存（%@）。粘贴新的 Key 可替换。"),
        ("Paste your Alibaba Cloud API Key", "粘贴阿里云 API Key"),
        ("Paste your Volcengine API Key", "粘贴火山引擎 API Key"),
        ("Not Set", "未设置"),
        ("Saved", "已保存"),
        ("Testing…", "测试中…"),
        ("Connected", "已连接"),
        ("Failed", "失败"),
        ("Connected · %lld ms. Ready to dictate.", "连接成功 · %lld ms，可以开始听写。"),
        ("Add an API key for %@.", "请为%@填写 API Key。"),
        ("Key saved (%@).", "Key 已保存（%@）。"),
        ("Connected · %lld ms", "已连接 · %lld ms"),
        ("The key works, but Kay couldn't save it to the Keychain.", "Key 可用，但未能保存到钥匙串。"),
    ]),
    ("Errors", [
        ("Enter the Alibaba Cloud workspace URL from the console.", "请填写阿里云控制台中的工作空间地址。"),
        ("Couldn't start Qwen ASR. Check your network and workspace URL.", "无法启动千问语音识别，请检查网络和工作空间地址。"),
        ("Qwen ASR is busy or your quota is exhausted. Check your Alibaba Cloud account and try again.", "千问语音识别繁忙或额度已用尽，请检查阿里云账号后重试。"),
        ("Qwen ASR couldn't finish this dictation. Try again or check your Alibaba Cloud account.", "千问语音识别未能完成本次听写，请重试或检查阿里云账号。"),
        ("Alibaba Cloud rejected this key. Copy the full API key for this workspace.",
         "阿里云拒绝了这个 Key，请完整复制当前工作空间的 API Key。"),
        ("This key can't use Qwen ASR in this workspace. Check the key, workspace and service access.",
         "这个 Key 无法使用当前工作空间的千问语音识别，请检查密钥、工作空间和服务权限。"),
        ("Couldn't reach Alibaba Cloud. Check your network and workspace URL.", "无法连接阿里云，请检查网络和工作空间地址。"),
        ("Unknown error", "未知错误"),
        ("Alibaba Cloud returned an unreadable response.", "阿里云返回了无法解析的响应。"),
        ("Volcengine rejected this key. Make sure you copied the whole key from the new console.",
         "火山引擎拒绝了这个 Key，请确认已从新版控制台完整复制。"),
        ("This key isn't enabled for Doubao Streaming ASR 2.0. Enable the service in the console, or switch the resource type.",
         "这个 Key 未开通豆包流式语音识别 2.0，请在控制台开通服务，或切换资源类型。"),
        ("Couldn't reach Volcengine. Check your network or proxy.", "无法连接火山引擎，请检查网络或代理。"),
        ("Malformed response from Volcengine.", "火山引擎返回了无法解析的响应。"),
        ("Doubao ASR couldn't finish this dictation. Try again or check your Volcengine account.",
         "豆包语音识别未能完成本次听写，请重试或检查火山引擎账号。"),
        ("Recognition timed out.", "识别超时。"),
        ("No microphone input is available.", "没有可用的麦克风输入。"),
    ]),
    ("Dictation", [
        ("No API key yet. Add one in Kay → Settings → Speech Service.", "还没有 API Key，请在 Kay → 设置 → 语音服务中填写。"),
        ("Kay can't use the microphone. Allow it in System Settings.", "Kay 无法使用麦克风，请在系统设置中允许。"),
        ("The microphone didn't start: %@", "麦克风启动失败：%@"),
        ("The microphone didn't respond.", "麦克风没有响应。"),
        ("Didn't catch that.", "没听清。"),
        ("System Default", "系统默认"),
        ("System Default (%@)", "系统默认（%@）"),
        ("Not Connected", "未连接"),
        ("When the chosen microphone isn't connected, Kay records from the system default.", "选中的麦克风没有连接时，Kay 用系统默认的麦克风录音。"),
        ("Show in Clipboard History", "出现在剪贴板历史中"),
        ("Pasting", "粘贴"),
        ("Kay pastes through the clipboard and then puts back what was there. When this is off, clipboard history apps such as Raycast leave dictations out.",
         "Kay 借剪贴板粘贴，粘贴后放回原来的内容。关闭后，Raycast 等剪贴板历史工具不会记录听写的文字。"),
        ("Recovered a dictation Kay didn't finish. It's in History.", "找回了一段没完成的听写，已放进历史。"),
        ("Copied. Kay needs Accessibility permission to paste for you.", "已复制。Kay 需要辅助功能权限才能自动粘贴。"),
    ]),
    ("Correction", [
        ("Correction", "纠错"),
        ("Fix Misheard Words", "纠正识别错误"),
        ("Add a DeepSeek API key below to turn this on.", "在下方填写 DeepSeek API Key 后生效。"),
        ("After recognition, DeepSeek V4.1 Flash corrects words the speech service misheard, such as product names, without rewording what you said. It adds about half a second. If DeepSeek doesn't answer within 3 seconds, Kay pastes what it heard.",
         "识别完成后，由 DeepSeek V4.1 Flash 改正语音服务听错的词（比如产品名），不改你的说法。每次多花大约半秒。DeepSeek 3 秒内没有回应时，Kay 直接粘贴识别结果。"),
        ("DeepSeek API Key", "DeepSeek API Key"),
        ("DeepSeek Platform → API Keys. DeepSeek bills you at its standard rates.", "DeepSeek 开放平台 → API Keys。费用由 DeepSeek 按标准价格收取。"),
        ("DeepSeek Platform", "DeepSeek 开放平台"),
        ("Paste your DeepSeek API Key", "粘贴 DeepSeek API Key"),
        ("It stays valid in DeepSeek. If it was exposed, revoke it on the DeepSeek Platform.",
         "它在 DeepSeek 中仍然有效。如果已经泄露，请到 DeepSeek 开放平台吊销。"),
        ("Couldn't reach DeepSeek.", "无法连接 DeepSeek。"),
        ("DeepSeek rejected this key.", "DeepSeek 拒绝了这个 Key。"),
        ("The DeepSeek account has run out of balance.", "DeepSeek 账户余额不足。"),
        ("DeepSeek returned an error: %@", "DeepSeek 返回错误：%@"),
        ("Vocabulary", "词表"),
        ("Save", "保存"),
        ("%lld terms", "%lld 个词"),
        ("Couldn't save the vocabulary.", "词表没能保存。"),
        ("Names you spell your own way, one per line. Kay fixes them when they come back spelled out (c f → CF, e to b → E2B). If one is misheard as something else, add that after a bar: Raycast | 瑞卡斯特. # starts a comment.",
         "你有固定写法的名字，一行一个。识别结果把它拆成字母时（c f → CF，e to b → E2B），Kay 会改回来。如果某个词总被听成别的，把听成的样子写在竖线后面：Raycast | 瑞卡斯特。# 之后是注释。"),
    ]),
]

INFO_PLIST_ZH = [
    ("NSMicrophoneUsageDescription", "Kay 只在你按住听写快捷键时录音，并把音频发送到你的语音服务转成文字。"),
]


def quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write(path, groups):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("/* Generated by scripts/localize.py — edit the table there, not this file. */\n")
        for title, pairs in groups:
            f.write(f"\n/* {title} */\n")
            for key, value in pairs:
                f.write(f"{quote(key)} = {quote(value)};\n")


def main():
    keys = [k for _, pairs in GROUPS for k, _ in pairs]
    dupes = {k for k in keys if keys.count(k) > 1}
    if dupes:
        raise SystemExit(f"duplicate keys: {sorted(dupes)}")
    res = os.path.join(ROOT, "macOS", "Resources")
    write(os.path.join(res, "en.lproj/Localizable.strings"), [(t, [(k, k) for k, _ in p]) for t, p in GROUPS])
    write(os.path.join(res, "zh-Hans.lproj/Localizable.strings"), GROUPS)
    write(os.path.join(res, "zh-Hans.lproj/InfoPlist.strings"), [("Info.plist", INFO_PLIST_ZH)])
    print(f"{len(keys)} strings")


if __name__ == "__main__":
    main()
