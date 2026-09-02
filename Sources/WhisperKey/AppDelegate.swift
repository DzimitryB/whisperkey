import AppKit
import AVFoundation
import Carbon.HIToolbox
import IOKit.hid
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State {
        case idle
        case recording(start: Date)
        case processing
    }

    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private var state: State = .idle
    private var mainHotKeyID: UInt32?
    private var modifierMonitor: ModifierKeyMonitor?
    private var escHotKeyID: UInt32?
    private var recordingTimer: Timer?
    private var lastTranscript: String = ""

    private let maxRecordingSeconds: TimeInterval = 600

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "autoPaste": false,
            "holdMode": true,
            "sounds": false,
            "language": "auto",
            "engineProvider": "local",
            "engineModel": "",
            "hotKeyCode": Int(kVK_Space),
            "hotKeyModifiers": Int(optionKey),
            "hotKeyModifierOnly": false,
            "modifierHotKeyProven": false,
        ])

        // Snapshot mode: only render HUD states to PNG, no hotkeys/permissions/status item.
        if let idx = CommandLine.arguments.firstIndex(of: "--hud-shot"),
           CommandLine.arguments.count > idx + 1 {
            runHUDShots(directory: CommandLine.arguments[idx + 1])
            return
        }

        chooseUILanguageIfNeeded()
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        applyIcon(symbol: "mic", tint: nil)
        rebuildMenu()

        ModelManager.shared.onDownloadStateChange = { [weak self] in self?.rebuildMenu() }

        registerMainHotKey()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // NSEvent monitors can go quiet after system sleep — re-arm on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.registerMainHotKey()
        }

        if CommandLine.arguments.contains("--hud-test") {
            runHUDTest()
        }
    }

    /// First launch: let the user pick the interface language (system language preselected).
    private func chooseUILanguageIfNeeded() {
        guard !L10n.hasStoredChoice, !CommandLine.arguments.contains("--hud-test") else { return }
        let alert = NSAlert()
        alert.messageText = L("firstrun.title")
        alert.informativeText = L("firstrun.text")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        popup.addItems(withTitles: L10n.languages.map { $0.name })
        if let idx = L10n.languages.firstIndex(where: { $0.code == L10n.systemDefault() }) {
            popup.selectItem(at: idx)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: L("btn.continue"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        L10n.current = L10n.languages[popup.indexOfSelectedItem].code
    }

    /// Saves PNG snapshots of the three HUD states into the given directory, then quits.
    private func runHUDShots(directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        HUD.shared.showRecording()
        HUD.shared.updateLevel(0.25)
        HUD.shared.updateTime(7)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            HUD.shared.saveSnapshot(to: dir.appendingPathComponent("hud-recording.png"))
            HUD.shared.showProcessing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                HUD.shared.saveSnapshot(to: dir.appendingPathComponent("hud-processing.png"))
                HUD.shared.showDone(success: true, text: L("hud.done"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    HUD.shared.saveSnapshot(to: dir.appendingPathComponent("hud-done.png"))
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Menu-bar apps have no visible main menu, but without an Edit menu the standard
    /// ⌘V/⌘C/⌘X/⌘A shortcuts don't reach text fields in our dialogs (e.g. the API key prompt).
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: L("edit.title"))
        edit.addItem(withTitle: L("edit.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("edit.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("edit.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("edit.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("edit.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("edit.all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = mainMenu
    }

    /// Cycles the HUD through all states so it can be checked visually: --hud-test
    private func runHUDTest() {
        HUD.shared.showRecording()
        var elapsed = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { timer in
            elapsed += 0.08
            HUD.shared.updateLevel(Float.random(in: 0.05...0.5))
            HUD.shared.updateTime(Int(elapsed))
            if elapsed >= 3 {
                timer.invalidate()
                HUD.shared.showProcessing()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    HUD.shared.showDone(success: true, text: L("hud.done"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
                }
            }
        }
    }

    // MARK: - Hotkeys

    private var hotKeyCode: UInt32 { UInt32(UserDefaults.standard.integer(forKey: "hotKeyCode")) }
    private var hotKeyModifiers: UInt32 { UInt32(UserDefaults.standard.integer(forKey: "hotKeyModifiers")) }
    private var hotKeyModifierOnly: Bool { UserDefaults.standard.bool(forKey: "hotKeyModifierOnly") }

    private var hotKeyTitle: String {
        HotKeyPreset.all.first {
            $0.keyCode == hotKeyCode
                && $0.modifierOnly == hotKeyModifierOnly
                && ($0.modifierOnly || $0.modifiers == hotKeyModifiers)
        }?.title ?? "⌥ \(L("key.space"))"
    }

    private var holdMode: Bool { UserDefaults.standard.bool(forKey: "holdMode") }

    private var currentEngine: EngineOption {
        let providerID = UserDefaults.standard.string(forKey: "engineProvider") ?? "local"
        let model = UserDefaults.standard.string(forKey: "engineModel") ?? ""
        return EngineOption.all.first {
            ($0.provider?.id ?? "local") == providerID && ($0.model ?? "") == model
        } ?? EngineOption.all[0]
    }

    private func registerMainHotKey() {
        if let id = mainHotKeyID {
            HotKeyCenter.shared.unregister(id)
            mainHotKeyID = nil
        }
        modifierMonitor?.stop()
        modifierMonitor = nil

        if hotKeyModifierOnly, let monitor = ModifierKeyMonitor(keyCode: UInt16(hotKeyCode)) {
            monitor.onPress = { [weak self] in self?.hotKeyPressed() }
            monitor.onRelease = { [weak self] in self?.hotKeyReleased() }
            monitor.onOtherKeyDown = { [weak self] in
                // The modifier is being used as a normal modifier (⌘C etc.) — not dictation.
                guard let self, self.holdMode, case .recording = self.state else { return }
                self.cancelRecording()
            }
            monitor.start()
            modifierMonitor = monitor
        } else {
            mainHotKeyID = HotKeyCenter.shared.register(
                keyCode: hotKeyCode,
                modifiers: hotKeyModifiers,
                pressed: { [weak self] in self?.hotKeyPressed() },
                released: { [weak self] in self?.hotKeyReleased() }
            )
        }
    }

    /// Global keyboard monitoring works with EITHER Accessibility OR Input Monitoring —
    /// macOS may grant it through either list, so check both before complaining.
    private var canMonitorKeyboard: Bool {
        AXIsProcessTrusted()
            || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// TCC status APIs can under-report for ad-hoc signed apps, so the ultimate truth
    /// is empirical: once the modifier hotkey has actually fired, it obviously works.
    private var modifierHotKeyProven: Bool {
        UserDefaults.standard.bool(forKey: "modifierHotKeyProven")
    }

    private func markModifierHotKeyProven() {
        guard hotKeyModifierOnly, !modifierHotKeyProven else { return }
        UserDefaults.standard.set(true, forKey: "modifierHotKeyProven")
        rebuildMenu()
    }

    /// Modifier-only hotkeys need Accessibility/Input Monitoring for global key events.
    /// Asked only on explicit user action (choosing the preset), never at launch.
    private func warnIfModifierHotKeyUnavailable() {
        guard hotKeyModifierOnly, !canMonitorKeyboard, !modifierHotKeyProven else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        showAlert(title: L("alert.axTitle"), text: L("alert.axText"))
    }

    // MARK: - Recording flow

    private func hotKeyPressed() {
        markModifierHotKeyProven()
        if holdMode {
            // Key repeat can fire extra "pressed" events while held — only act from idle.
            if case .idle = state { startRecording() }
        } else {
            toggleRecording()
        }
    }

    private func hotKeyReleased() {
        guard holdMode else { return }
        if case .recording = state { stopAndTranscribe() }
    }

    @objc private func toggleRecording() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopAndTranscribe()
        case .processing:
            if soundsEnabled { NSSound.beep() }
        }
    }

    private var soundsEnabled: Bool { UserDefaults.standard.bool(forKey: "sounds") }

    private func playSound(_ name: String) {
        guard soundsEnabled else { return }
        NSSound(named: name)?.play()
    }

    private func startRecording() {
        let engine = currentEngine
        if let provider = engine.provider {
            guard KeyStore.has(account: provider.id) else {
                promptForAPIKey(provider: provider)
                return
            }
        } else {
            guard ModelManager.shared.defaultModelURL != nil else {
                showAlert(title: L("alert.noModel"), text: L("alert.noModel.text"))
                return
            }
            guard Transcriber.findCLI() != nil else {
                showAlert(title: L("alert.noCli"), text: L("alert.noCli.text"))
                return
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async { if granted { self?.startRecording() } }
            }
            return
        default:
            showAlert(title: L("alert.noMic"), text: L("alert.noMic.text"))
            return
        }

        // Handlers are set before start(): the first buffers can arrive very quickly.
        recorder.onFirstBuffer = { [weak self] in
            DispatchQueue.main.async { self?.captureDidStart() }
        }
        recorder.levelHandler = { level in
            DispatchQueue.main.async { HUD.shared.updateLevel(level) }
        }
        do {
            try recorder.start()
        } catch {
            showAlert(title: L("alert.recFail"), text: error.localizedDescription)
            return
        }

        // The mic hardware needs a moment (Bluetooth mics up to ~1 s) before real
        // audio flows; until then show "starting" so the user doesn't speak into the void.
        state = .recording(start: Date())
        applyIcon(symbol: "mic.fill", tint: .systemOrange)
        HUD.shared.showPreparing()

        escHotKeyID = HotKeyCenter.shared.register(
            keyCode: UInt32(kVK_Escape),
            modifiers: 0,
            pressed: { [weak self] in self?.cancelRecording() }
        )

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recordingTick()
        }
        rebuildMenu()
    }

    /// First audio buffer arrived — capture is really live: now show "recording".
    private func captureDidStart() {
        guard case .recording = state else { return }
        state = .recording(start: Date())
        playSound("Pop")
        applyIcon(symbol: "mic.fill", tint: .systemRed)
        HUD.shared.showRecording()
        rebuildMenu()
    }

    private func recordingTick() {
        guard case .recording(let start) = state else { return }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= maxRecordingSeconds {
            stopAndTranscribe()
        } else {
            HUD.shared.updateTime(Int(elapsed))
            rebuildMenu()
        }
    }

    @objc private func cancelRecording() {
        guard case .recording = state else { return }
        endRecordingUI()
        recorder.cancel()
        state = .idle
        applyIcon(symbol: "mic", tint: nil)
        HUD.shared.hide()
        rebuildMenu()
    }

    @objc private func stopAndTranscribe() {
        guard case .recording = state else { return }
        endRecordingUI()

        let engine = currentEngine
        let localModel = ModelManager.shared.defaultModelURL

        guard let wav = recorder.stop(), engine.provider != nil || localModel != nil else {
            state = .idle
            applyIcon(symbol: "mic", tint: nil)
            HUD.shared.hide()
            rebuildMenu()
            return
        }

        state = .processing
        applyIcon(symbol: "hourglass", tint: .systemOrange)
        if let provider = engine.provider {
            HUD.shared.showProcessing(text: L("hud.processingVia", provider.title))
        } else {
            HUD.shared.showProcessing()
        }
        rebuildMenu()

        let language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var usedFallback = false
            let result = Result { () throws -> String in
                if let provider = engine.provider,
                   let cloudModel = engine.model,
                   let apiKey = KeyStore.get(account: provider.id) {
                    do {
                        return try CloudTranscriber.transcribe(
                            wav: wav, provider: provider, model: cloudModel,
                            language: language, apiKey: apiKey
                        )
                    } catch {
                        // Cloud failed — fall back to the local model when possible.
                        guard let localModel, Transcriber.findCLI() != nil else { throw error }
                        let text = try Transcriber.transcribe(wav: wav, model: localModel, language: language)
                        usedFallback = true
                        return text
                    }
                }
                guard let localModel else {
                    throw Transcriber.TranscriberError.failed(L("err.nolocal"))
                }
                return try Transcriber.transcribe(wav: wav, model: localModel, language: language)
            }
            try? FileManager.default.removeItem(at: wav)
            DispatchQueue.main.async {
                self?.finishTranscription(result, usedFallback: usedFallback)
            }
        }
    }

    private func endRecordingUI() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        if let id = escHotKeyID {
            HotKeyCenter.shared.unregister(id)
            escHotKeyID = nil
        }
    }

    private func finishTranscription(_ result: Result<String, Error>, usedFallback: Bool = false) {
        state = .idle
        applyIcon(symbol: "mic", tint: nil)
        switch result {
        case .success(let text) where !text.isEmpty:
            lastTranscript = text
            playSound("Glass")
            TextInserter.insert(text)
            HUD.shared.showDone(success: true, text: usedFallback ? L("hud.fallback") : L("hud.done"))
        case .success:
            if soundsEnabled { NSSound.beep() }
            HUD.shared.showDone(success: false, text: L("hud.empty"))
        case .failure(let error):
            if soundsEnabled { NSSound.beep() }
            HUD.shared.showDone(success: false, text: L("hud.fail"))
            showAlert(title: L("alert.trFail"), text: error.localizedDescription)
        }
        rebuildMenu()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        let statusTitle: String
        switch state {
        case .idle:
            statusTitle = holdMode
                ? L("status.hold", hotKeyTitle)
                : L("status.ready", hotKeyTitle)
        case .recording(let start):
            let seconds = Int(Date().timeIntervalSince(start))
            let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
            statusTitle = holdMode ? L("status.rec.hold", time) : L("status.rec", time)
        case .processing:
            statusTitle = L("status.processing")
        }
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        // Silent hint instead of popups: modifier-only hotkey needs Accessibility.
        // Skipped once the hotkey has demonstrably fired at least once.
        if hotKeyModifierOnly && !canMonitorKeyboard && !modifierHotKeyProven {
            let warn = NSMenuItem(title: L("warn.rightcmd"), action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            menu.addItem(makeItem(L("menu.axSettings"), action: #selector(openAccessibilitySettings)))
        }

        switch state {
        case .idle:
            menu.addItem(makeItem(L("menu.record"), action: #selector(toggleRecording)))
        case .recording:
            menu.addItem(makeItem(L("menu.finish"), action: #selector(stopAndTranscribe)))
            menu.addItem(makeItem(L("menu.cancel"), action: #selector(cancelRecording)))
        case .processing:
            break
        }

        if !lastTranscript.isEmpty {
            menu.addItem(.separator())
            let preview = lastTranscript.count > 60
                ? String(lastTranscript.prefix(60)) + "…"
                : lastTranscript
            menu.addItem(makeItem(L("menu.copy", preview), action: #selector(copyLastTranscript)))
        }

        menu.addItem(.separator())
        menu.addItem(buildEngineMenu())
        menu.addItem(buildModelMenu())
        menu.addItem(buildLanguageMenu())
        menu.addItem(buildHotKeyMenu())
        menu.addItem(buildModeMenu())
        menu.addItem(buildUILanguageMenu())

        let autoPaste = makeItem(L("menu.autopaste"), action: #selector(toggleAutoPaste))
        autoPaste.state = UserDefaults.standard.bool(forKey: "autoPaste") ? .on : .off
        menu.addItem(autoPaste)

        let sounds = makeItem(L("menu.sounds"), action: #selector(toggleSounds))
        sounds.state = soundsEnabled ? .on : .off
        menu.addItem(sounds)

        menu.addItem(.separator())
        menu.addItem(makeItem(L("menu.modelsFolder"), action: #selector(openModelsFolder)))
        let loginItem = makeItem(L("menu.login"), action: #selector(toggleLoginItem))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(makeItem(L("menu.quit"), action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func buildEngineMenu() -> NSMenuItem {
        let root = NSMenuItem(title: L("menu.engine"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = currentEngine

        for (index, option) in EngineOption.all.enumerated() {
            let item = makeItem(option.title, action: #selector(selectEngine(_:)))
            item.tag = index
            item.state = (
                (option.provider?.id ?? "local") == (current.provider?.id ?? "local")
                    && option.model == current.model
            ) ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        for provider in CloudProvider.all {
            let saved = KeyStore.has(account: provider.id) ? L("apikey.saved") : ""
            let item = makeItem(L("apikey.item", provider.title) + saved, action: #selector(enterAPIKey(_:)))
            item.representedObject = provider.id
            submenu.addItem(item)
        }

        root.submenu = submenu
        return root
    }

    private func buildModelMenu() -> NSMenuItem {
        let manager = ModelManager.shared
        let root = NSMenuItem(title: L("menu.model"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let installed = manager.installedModels()
        if installed.isEmpty {
            let none = NSMenuItem(title: L("models.none"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        for file in installed {
            let title = file
                .replacingOccurrences(of: "ggml-", with: "")
                .replacingOccurrences(of: ".bin", with: "")
            let item = makeItem(title, action: #selector(selectModel(_:)))
            item.representedObject = file
            item.state = manager.defaultModelFile == file ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        let header = NSMenuItem(title: L("models.download"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)

        for model in ModelManager.catalog {
            if let progress = manager.downloads[model.file] {
                let item = NSMenuItem(
                    title: "\(model.title) — \(Int(progress * 100))%",
                    action: nil, keyEquivalent: ""
                )
                item.isEnabled = false
                submenu.addItem(item)
            } else if installed.contains(model.file) {
                continue
            } else {
                let item = makeItem(model.title, action: #selector(downloadModel(_:)))
                item.representedObject = model.file
                submenu.addItem(item)
            }
        }

        root.submenu = submenu
        return root
    }

    private func buildLanguageMenu() -> NSMenuItem {
        let root = NSMenuItem(title: L("menu.speechLang"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = UserDefaults.standard.string(forKey: "language") ?? "auto"
        let options: [(String, String)] = [
            (L("speech.auto"), "auto"),
            (L("speech.ru"), "ru"),
            (L("speech.en"), "en"),
        ]
        for (title, code) in options {
            let item = makeItem(title, action: #selector(selectLanguage(_:)))
            item.representedObject = code
            item.state = current == code ? .on : .off
            submenu.addItem(item)
        }
        root.submenu = submenu
        return root
    }

    private func buildHotKeyMenu() -> NSMenuItem {
        let root = NSMenuItem(title: L("menu.hotkey"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, preset) in HotKeyPreset.all.enumerated() {
            let item = makeItem(preset.title, action: #selector(selectHotKey(_:)))
            item.tag = index
            item.state = (
                preset.keyCode == hotKeyCode
                    && preset.modifierOnly == hotKeyModifierOnly
                    && (preset.modifierOnly || preset.modifiers == hotKeyModifiers)
            ) ? .on : .off
            submenu.addItem(item)
        }
        root.submenu = submenu
        return root
    }

    private func buildModeMenu() -> NSMenuItem {
        let root = NSMenuItem(title: L("menu.mode"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let hold = makeItem(L("mode.hold"), action: #selector(selectMode(_:)))
        hold.representedObject = true
        hold.state = holdMode ? .on : .off
        submenu.addItem(hold)

        let toggle = makeItem(L("mode.toggle"), action: #selector(selectMode(_:)))
        toggle.representedObject = false
        toggle.state = holdMode ? .off : .on
        submenu.addItem(toggle)

        root.submenu = submenu
        return root
    }

    private func buildUILanguageMenu() -> NSMenuItem {
        let root = NSMenuItem(title: L("menu.uiLang"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for language in L10n.languages {
            let item = makeItem(language.name, action: #selector(selectUILanguage(_:)))
            item.representedObject = language.code
            item.state = L10n.current == language.code ? .on : .off
            submenu.addItem(item)
        }
        root.submenu = submenu
        return root
    }

    private func makeItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - Menu actions

    @objc private func copyLastTranscript() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastTranscript, forType: .string)
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        let option = EngineOption.all[sender.tag]
        UserDefaults.standard.set(option.provider?.id ?? "local", forKey: "engineProvider")
        UserDefaults.standard.set(option.model ?? "", forKey: "engineModel")
        if let provider = option.provider, !KeyStore.has(account: provider.id) {
            promptForAPIKey(provider: provider)
        }
        rebuildMenu()
    }

    @objc private func enterAPIKey(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let provider = CloudProvider.by(id: id) else { return }
        promptForAPIKey(provider: provider)
        rebuildMenu()
    }

    /// The user types/pastes their own key; it is stored in the app's key file.
    private func promptForAPIKey(provider: CloudProvider) {
        let alert = NSAlert()
        alert.messageText = L("apikey.title", provider.title)
        alert.informativeText = KeyStore.has(account: provider.id)
            ? L("apikey.replace")
            : L("apikey.info", provider.title, provider.title)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = provider.keyPlaceholder
        alert.accessoryView = field
        alert.addButton(withTitle: L("btn.save"))
        alert.addButton(withTitle: L("btn.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        KeyStore.set(key, account: provider.id)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String else { return }
        ModelManager.shared.defaultModelFile = file
        rebuildMenu()
    }

    @objc private func downloadModel(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String else { return }
        ModelManager.shared.download(file: file)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: "language")
        rebuildMenu()
    }

    @objc private func selectHotKey(_ sender: NSMenuItem) {
        let preset = HotKeyPreset.all[sender.tag]
        UserDefaults.standard.set(Int(preset.keyCode), forKey: "hotKeyCode")
        UserDefaults.standard.set(Int(preset.modifiers), forKey: "hotKeyModifiers")
        UserDefaults.standard.set(preset.modifierOnly, forKey: "hotKeyModifierOnly")
        registerMainHotKey()
        warnIfModifierHotKeyUnavailable()
        rebuildMenu()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let hold = sender.representedObject as? Bool else { return }
        UserDefaults.standard.set(hold, forKey: "holdMode")
        rebuildMenu()
    }

    @objc private func selectUILanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        L10n.current = code
        installMainMenu()
        rebuildMenu()
    }

    @objc private func toggleAutoPaste() {
        let enabling = !UserDefaults.standard.bool(forKey: "autoPaste")
        UserDefaults.standard.set(enabling, forKey: "autoPaste")
        if enabling && !AXIsProcessTrusted() {
            // The only moment we ask for Accessibility for pasting: explicit user action.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        rebuildMenu()
    }

    @objc private func toggleSounds() {
        UserDefaults.standard.set(!soundsEnabled, forKey: "sounds")
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openModelsFolder() {
        NSWorkspace.shared.open(ModelManager.shared.modelsDirectory)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showAlert(title: L("alert.loginFail"), text: error.localizedDescription)
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func applyIcon(symbol: String, tint: NSColor?) {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WhisperKey")
        image?.isTemplate = tint == nil
        button.image = image
        button.contentTintColor = tint
    }

    private func showAlert(title: String, text: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
