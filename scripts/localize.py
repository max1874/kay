#!/usr/bin/env python3
"""Emits Resources/{en,zh-Hans}.lproj/Localizable.strings (and zh-Hans InfoPlist.strings) from one table.

Run it by hand after changing a user-visible string; the .strings files are committed, so a
build never needs Python. English is the key, so en.lproj is key == value.
Interpolations follow Swift's format keys: Int -> %lld, String -> %@.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

GROUPS = [
    ("Menus", [
        ("About Kay", "关于 Kay"),
        ("Settings…", "设置…"),
        ("Hide Kay", "隐藏 Kay"),
        ("Hide Others", "隐藏其他"),
        ("Show All", "全部显示"),
        ("Quit Kay", "退出 Kay"),
        ("Edit", "编辑"),
        ("Undo", "撤销"),
        ("Redo", "重做"),
        ("Cut", "剪切"),
        ("Copy", "拷贝"),
        ("Paste", "粘贴"),
        ("Select All", "全选"),
        ("Window", "窗口"),
        ("Minimize", "最小化"),
        ("Close", "关闭"),
        ("Kay Window", "Kay 主窗口"),
        ("Open Kay", "打开 Kay"),
    ]),
    ("Sidebar", [
        ("Home", "首页"),
        ("History", "历史"),
        ("Speech Service", "语音服务"),
        ("General", "通用"),
    ]),
    ("Home", [
        ("Hold Right Option and speak. Let go, and the text appears where your cursor is.",
         "按住右 Option 说话，松开后文字会出现在光标处。"),
        ("Listening…", "正在听…"),
        ("Recognizing…", "识别中…"),
        ("Ready", "准备就绪"),
        ("A few things to set up", "还有几项要设置"),
        ("Before You Start", "开始之前"),
        ("Microphone", "麦克风"),
        ("Kay records only while you hold the key.", "只在你按住快捷键时录音。"),
        ("Allow", "允许"),
        ("Accessibility", "辅助功能"),
        ("Lets Kay notice Right Option and paste the text for you.", "用来识别右 Option 按键，并把文字粘贴到光标处。"),
        ("Open Settings", "打开系统设置"),
        ("Set Up", "去设置"),
        ("Usage", "用量"),
        ("Dictations today", "今天听写次数"),
        ("Characters dictated", "累计听写字数"),
        ("Audio sent", "累计音频时长"),
        ("Counted on this Mac. Volcengine bills by audio length; your actual bill is in its console.",
         "由这台 Mac 统计。火山引擎按音频时长计费，实际账单以控制台为准。"),
        ("Console ↗", "控制台 ↗"),
        ("Recent", "最近"),
        ("Nothing yet. Hold Right Option and say something.", "还没有记录。按住右 Option 说句话试试。"),
        ("Show All History", "查看全部历史"),
    ]),
    ("History", [
        ("No Dictations Yet", "还没有听写记录"),
        ("Hold Right Option and say something.", "按住右 Option 说句话试试。"),
        ("Delete", "删除"),
        ("Search", "搜索"),
        ("Clear All…", "全部清除…"),
        ("Delete all dictation history?", "删除全部听写历史？"),
        ("Delete All", "全部删除"),
        ("This can't be undone.", "此操作无法撤销。"),
    ]),
    ("Speech Service", [
        ("Volcengine Doubao", "火山引擎 · 豆包语音"),
        ("Streaming ASR 2.0 · sentence mode", "流式语音识别 2.0 · 一句话模式"),
        ("Kay uses your own Volcengine account. Audio goes straight from this Mac to Volcengine, your key stays in the macOS Keychain, and Volcengine bills you at its standard rates.",
         "Kay 使用你自己的火山引擎账号。音频从这台 Mac 直接发送到火山引擎，密钥只保存在 macOS 钥匙串中，费用由火山引擎按标准价格向你收取。"),
        ("API Key", "API Key"),
        ("Volcengine console → Doubao Speech → API Key (new console).", "火山引擎控制台 → 豆包语音 → API Key（新版控制台）。"),
        ("Resource", "资源类型"),
        ("Hourly", "小时版"),
        ("Concurrent", "并发版"),
        ("Test Again", "重新测试"),
        ("Test & Save", "测试并保存"),
        ("Get an API Key ↗", "获取 API Key ↗"),
        ("Enable the Service ↗", "开通服务 ↗"),
        ("Remove Key…", "移除 Key…"),
        ("Other Providers", "其他服务商"),
        ("Alibaba Qwen ASR", "阿里千问语音识别"),
        ("Coming soon", "即将支持"),
        ("Remove this key from Kay?", "从 Kay 移除这个 Key？"),
        ("Remove", "移除"),
        ("It stays valid in Volcengine. If it was exposed, revoke it in the console.",
         "它在火山引擎中仍然有效。如果已经泄露，请到控制台吊销。"),
        ("Saved (%@). Paste a new key to replace it.", "已保存（%@）。粘贴新的 Key 可替换。"),
        ("Paste your Volcengine API Key", "粘贴火山引擎 API Key"),
        ("Not Set", "未设置"),
        ("Saved", "已保存"),
        ("Testing…", "测试中…"),
        ("Connected", "已连接"),
        ("Failed", "失败"),
        ("Connected · %lld ms. Ready to dictate.", "连接成功 · %lld ms，可以开始听写。"),
        ("Add your Volcengine API key.", "填写你的火山引擎 API Key。"),
        ("Key saved (%@).", "Key 已保存（%@）。"),
        ("Connected · %lld ms", "已连接 · %lld ms"),
        ("The key works, but Kay couldn't save it to the Keychain.", "Key 可用，但未能保存到钥匙串。"),
    ]),
    ("Errors", [
        ("Volcengine rejected this key. Make sure you copied the whole key from the new console.",
         "火山引擎拒绝了这个 Key，请确认已从新版控制台完整复制。"),
        ("This key isn't enabled for Doubao Streaming ASR 2.0. Enable the service in the console, or switch the resource type.",
         "这个 Key 未开通豆包流式语音识别 2.0，请在控制台开通服务，或切换资源类型。"),
        ("Couldn't reach Volcengine. Check your network or proxy.", "无法连接火山引擎，请检查网络或代理。"),
        ("Unknown error", "未知错误"),
        ("Malformed response from Volcengine.", "火山引擎返回了无法解析的响应。"),
        ("Recognition timed out.", "识别超时。"),
        ("No microphone input is available.", "没有可用的麦克风输入。"),
    ]),
    ("Dictation", [
        ("No API key yet. Add one in Kay → Speech Service.", "还没有 API Key，请在 Kay → 语音服务中填写。"),
        ("Kay can't use the microphone. Allow it in System Settings.", "Kay 无法使用麦克风，请在系统设置中允许。"),
        ("The microphone didn't start: %@", "麦克风启动失败：%@"),
        ("Listening", "正在听"),
        ("Listening  %llds", "正在听  %lld 秒"),
        ("Didn't catch that.", "没听清。"),
        ("Copied. Kay needs Accessibility permission to paste for you.", "已复制。Kay 需要辅助功能权限才能自动粘贴。"),
    ]),
    ("General", [
        ("Shortcut", "快捷键"),
        ("Hold to talk", "按住说话"),
        ("Right Option ⌥", "右 Option ⌥"),
        ("Pressing any other key while you hold it cancels the recording, so ⌥ shortcuts keep working.",
         "按住时再按其他键会取消本次录音，所以 ⌥ 组合键照常可用。"),
        ("Permissions", "权限"),
        ("Granted", "已授权"),
        ("App", "应用"),
        ("Open at Login", "登录时打开"),
        ("Show in Menu Bar", "在菜单栏显示"),
        ("Version", "版本"),
        ("Show in Finder", "在访达中显示"),
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
    res = os.path.join(ROOT, "Resources")
    write(os.path.join(res, "en.lproj/Localizable.strings"), [(t, [(k, k) for k, _ in p]) for t, p in GROUPS])
    write(os.path.join(res, "zh-Hans.lproj/Localizable.strings"), GROUPS)
    write(os.path.join(res, "zh-Hans.lproj/InfoPlist.strings"), [("Info.plist", INFO_PLIST_ZH)])
    print(f"{len(keys)} strings")


if __name__ == "__main__":
    main()
