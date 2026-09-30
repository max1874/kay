import AppKit
import AVFoundation
import os

let log = Logger(subsystem: "com.max1874.kay", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State { case idle, recording, processing }

    /// 按住不足这个时长视为误触，不识别。
    private static let minHold: TimeInterval = 0.3

    private var statusItem: NSStatusItem!
    private var lastResultItem: NSMenuItem!
    private let hud = HUD()
    private let hotkey = HotkeyMonitor()
    private var capture: AudioCapture?
    private var session: DoubaoSession?
    private var pressedAt = Date()
    private var tick: Timer?
    private var permissionPoll: Timer?
    private var lastResult = ""

    private var state = State.idle {
        didSet { updateIcon() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        hotkey.onPress = { [weak self] in self?.begin() }
        hotkey.onRelease = { [weak self] in self?.end() }
        hotkey.onInterrupt = { [weak self] in self?.cancel() }
        hotkey.start()

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !AXIsProcessTrusted() { waitForAccessibility(prompt: true) }
        if ConfigStore.load() == nil { promptForApiKey() }
    }

    // MARK: - 按住说话

    private func begin() {
        guard state == .idle else { return }
        guard let config = ConfigStore.load() else {
            hud.flash("未设置 API Key")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hud.flash("没有麦克风权限，请在系统设置中允许 Kay")
            return
        }

        let session = DoubaoSession(apiKey: config.volcApiKey)
        let capture = AudioCapture()
        capture.onChunk = { [weak session] in session?.sendAudio($0) }
        do {
            try capture.start()
        } catch {
            hud.flash("麦克风启动失败：\(error.localizedDescription)")
            return
        }
        session.start()

        self.session = session
        self.capture = capture
        pressedAt = Date()
        state = .recording
        hud.show("● 正在听")
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.hud.show("● 正在听  \(Int(Date().timeIntervalSince(self.pressedAt)))s")
        }
    }

    private func end() {
        guard state == .recording, let session, let capture else { return }
        tick?.invalidate()
        let rest = capture.stop()
        self.capture = nil

        if Date().timeIntervalSince(pressedAt) < Self.minHold {
            cancel()
            return
        }

        state = .processing
        hud.show("识别中…")
        let releasedAt = Date()
        session.finish(lastChunk: rest) { [weak self] result in
            DispatchQueue.main.async {
                self?.deliver(result, latency: Date().timeIntervalSince(releasedAt))
            }
        }
    }

    private func deliver(_ result: Result<String, Error>, latency: TimeInterval) {
        session = nil
        state = .idle
        switch result {
        case .success(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            log.notice("final in \(Int(latency * 1000), privacy: .public) ms, \(text.count, privacy: .public) chars")
            guard !text.isEmpty else {
                hud.flash("没听清")
                return
            }
            remember(text)
            if AXIsProcessTrusted() {
                hud.hide()
                TextInserter.insert(text)
            } else {
                copyToPasteboard(text)
                hud.flash("已复制到剪贴板（未授予辅助功能权限，无法自动粘贴）", seconds: 3)
            }
        case .failure(let error):
            log.error("recognition failed: \(error.localizedDescription, privacy: .public)")
            hud.flash("识别失败：\(error.localizedDescription)", seconds: 3)
        }
    }

    private func cancel() {
        tick?.invalidate()
        _ = capture?.stop()
        capture = nil
        session?.cancel()
        session = nil
        state = .idle
        hud.hide()
    }

    // MARK: - 菜单

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "按住右 Option 说话，松开出字", action: nil, keyEquivalent: "")
        lastResultItem = menu.addItem(withTitle: "上次结果：无", action: #selector(copyLastResult), keyEquivalent: "")
        lastResultItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置 API Key…", action: #selector(promptForApiKey), keyEquivalent: "").target = self
        menu.addItem(withTitle: "辅助功能权限…", action: #selector(openAccessibilitySettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Kay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        updateIcon()
    }

    private func updateIcon() {
        let symbol: String
        switch state {
        case .idle: symbol = "mic"
        case .recording: symbol = "mic.fill"
        case .processing: symbol = "ellipsis.circle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Kay")
        image?.isTemplate = state != .recording
        statusItem?.button?.image = state == .recording
            ? image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            : image
    }

    private func remember(_ text: String) {
        lastResult = text
        let preview = text.count > 24 ? String(text.prefix(24)) + "…" : text
        lastResultItem.title = "上次结果：\(preview)（点击复制）"
    }

    @objc private func copyLastResult() {
        guard !lastResult.isEmpty else { return }
        copyToPasteboard(lastResult)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func promptForApiKey() {
        let alert = NSAlert()
        alert.messageText = "豆包语音 API Key"
        alert.informativeText = "火山引擎控制台 → 豆包语音 → API Key（新版控制台）"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = ConfigStore.load() == nil ? "粘贴 API Key" : "已设置，留空则不修改"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try ConfigStore.save(Config(volcApiKey: key))
        } catch {
            hud.flash("保存失败：\(error.localizedDescription)")
        }
    }

    @objc private func openAccessibilitySettings() {
        waitForAccessibility(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// 授权后重新注册全局按键监听，否则要重启 app 才生效。
    private func waitForAccessibility(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else { return }
        permissionPoll?.invalidate()
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.hotkey.start()
            log.notice("accessibility granted, hotkey monitor restarted")
        }
    }
}
