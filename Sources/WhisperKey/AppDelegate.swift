import AppKit
import AVFoundation
import Carbon.HIToolbox
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
        ])

        // Snapshot mode: only render HUD states to PNG, no hotkeys/permissions/status item.
        if let idx = CommandLine.arguments.firstIndex(of: "--hud-shot"),
           CommandLine.arguments.count > idx + 1 {
            runHUDShots(directory: CommandLine.arguments[idx + 1])
            return
        }

        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        applyIcon(symbol: "mic", tint: nil)
        rebuildMenu()

        ModelManager.shared.onDownloadStateChange = { [weak self] in self?.rebuildMenu() }

        registerMainHotKey()
        warnIfModifierHotKeyUnavailable()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        if CommandLine.arguments.contains("--hud-test") {
            runHUDTest()
        }
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
                HUD.shared.showDone(success: true, text: "Готово — текст в буфере")
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
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
                    HUD.shared.showDone(success: true, text: "Готово — текст в буфере")
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
        }?.title ?? "⌥ Пробел"
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

    /// Modifier-only hotkeys need Accessibility to see global keyboard events.
    private func warnIfModifierHotKeyUnavailable() {
        guard hotKeyModifierOnly, !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        showAlert(
            title: "Правому ⌘ нужно разрешение",
            text: "Чтобы реагировать на правый Command, дайте WhisperKey разрешение «Универсальный доступ»:\nНастройки системы → Конфиденциальность и безопасность → Универсальный доступ.\n\nПосле включения выберите «Правый ⌘» в меню ещё раз или перезапустите WhisperKey."
        )
    }

    // MARK: - Recording flow

    private func hotKeyPressed() {
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
            guard Keychain.has(account: provider.id) else {
                promptForAPIKey(provider: provider)
                return
            }
        } else {
            guard ModelManager.shared.defaultModelURL != nil else {
                showAlert(
                    title: "Нет модели",
                    text: "Скачайте модель распознавания через меню WhisperKey → Локальная модель → Скачать."
                )
                return
            }
            guard Transcriber.findCLI() != nil else {
                showAlert(
                    title: "Не найден whisper-cli",
                    text: "Установите движок распознавания:\nbrew install whisper-cpp"
                )
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
            showAlert(
                title: "Нет доступа к микрофону",
                text: "Разрешите доступ: Настройки системы → Конфиденциальность и безопасность → Микрофон → WhisperKey."
            )
            return
        }

        do {
            try recorder.start()
        } catch {
            showAlert(title: "Не удалось начать запись", text: error.localizedDescription)
            return
        }

        state = .recording(start: Date())
        playSound("Pop")
        applyIcon(symbol: "mic.fill", tint: .systemRed)
        HUD.shared.showRecording()
        recorder.levelHandler = { level in
            DispatchQueue.main.async { HUD.shared.updateLevel(level) }
        }

        escHotKeyID = HotKeyCenter.shared.register(
            keyCode: UInt32(kVK_Escape), modifiers: 0
        ) { [weak self] in
            self?.cancelRecording()
        }

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recordingTick()
        }
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
            HUD.shared.showProcessing(text: "Распознаю (\(provider.title))…")
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
                   let apiKey = Keychain.get(account: provider.id) {
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
                    throw Transcriber.TranscriberError.failed("нет локальной модели")
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
            HUD.shared.showDone(
                success: true,
                text: usedFallback ? "Готово (локально — облако недоступно)" : "Готово — текст в буфере"
            )
        case .success:
            if soundsEnabled { NSSound.beep() }
            HUD.shared.showDone(success: false, text: "Ничего не распозналось")
        case .failure(let error):
            if soundsEnabled { NSSound.beep() }
            HUD.shared.showDone(success: false, text: "Ошибка распознавания")
            showAlert(title: "Распознавание не удалось", text: error.localizedDescription)
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
                ? "WhisperKey — удерживайте \(hotKeyTitle)"
                : "WhisperKey — готов (\(hotKeyTitle))"
        case .recording(let start):
            let seconds = Int(Date().timeIntervalSince(start))
            let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
            statusTitle = holdMode ? "Запись… \(time) — отпустите клавишу" : "Запись… \(time)"
        case .processing:
            statusTitle = "Распознаю…"
        }
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        switch state {
        case .idle:
            menu.addItem(makeItem("Начать запись", action: #selector(toggleRecording)))
        case .recording:
            menu.addItem(makeItem("Готово — распознать и вставить", action: #selector(stopAndTranscribe)))
            menu.addItem(makeItem("Отменить (Esc)", action: #selector(cancelRecording)))
        case .processing:
            break
        }

        if !lastTranscript.isEmpty {
            menu.addItem(.separator())
            let preview = lastTranscript.count > 60
                ? String(lastTranscript.prefix(60)) + "…"
                : lastTranscript
            let item = makeItem("Скопировать: «\(preview)»", action: #selector(copyLastTranscript))
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(buildEngineMenu())
        menu.addItem(buildModelMenu())
        menu.addItem(buildLanguageMenu())
        menu.addItem(buildHotKeyMenu())
        menu.addItem(buildModeMenu())

        let autoPaste = makeItem("Автовставка в активное поле", action: #selector(toggleAutoPaste))
        autoPaste.state = UserDefaults.standard.bool(forKey: "autoPaste") ? .on : .off
        menu.addItem(autoPaste)

        let sounds = makeItem("Звуковые сигналы", action: #selector(toggleSounds))
        sounds.state = soundsEnabled ? .on : .off
        menu.addItem(sounds)

        menu.addItem(.separator())
        menu.addItem(makeItem("Открыть папку моделей", action: #selector(openModelsFolder)))
        let loginItem = makeItem("Запускать при входе", action: #selector(toggleLoginItem))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("Выйти", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func buildEngineMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "Распознавание", action: nil, keyEquivalent: "")
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
            let saved = Keychain.has(account: provider.id)
            let item = makeItem(
                "API-ключ \(provider.title)…\(saved ? " (сохранён)" : "")",
                action: #selector(enterAPIKey(_:))
            )
            item.representedObject = provider.id
            submenu.addItem(item)
        }

        root.submenu = submenu
        return root
    }

    private func buildModelMenu() -> NSMenuItem {
        let manager = ModelManager.shared
        let root = NSMenuItem(title: "Локальная модель", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let installed = manager.installedModels()
        if installed.isEmpty {
            let none = NSMenuItem(title: "Нет установленных моделей", action: nil, keyEquivalent: "")
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
        let header = NSMenuItem(title: "Скачать:", action: nil, keyEquivalent: "")
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
        let root = NSMenuItem(title: "Язык", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = UserDefaults.standard.string(forKey: "language") ?? "auto"
        let options: [(String, String)] = [
            ("Определять автоматически", "auto"),
            ("Русский", "ru"),
            ("English", "en"),
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
        let root = NSMenuItem(title: "Горячая клавиша", action: nil, keyEquivalent: "")
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
        let root = NSMenuItem(title: "Режим записи", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let hold = makeItem("Удерживать клавишу (push-to-talk)", action: #selector(selectMode(_:)))
        hold.representedObject = true
        hold.state = holdMode ? .on : .off
        submenu.addItem(hold)

        let toggle = makeItem("Нажать — начать, нажать — закончить", action: #selector(selectMode(_:)))
        toggle.representedObject = false
        toggle.state = holdMode ? .off : .on
        submenu.addItem(toggle)

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
        if let provider = option.provider, !Keychain.has(account: provider.id) {
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

    /// The user types/pastes their own key; it is stored in the login Keychain.
    private func promptForAPIKey(provider: CloudProvider) {
        let alert = NSAlert()
        alert.messageText = "API-ключ \(provider.title)"
        alert.informativeText = Keychain.has(account: provider.id)
            ? "Ключ уже сохранён. Введите новый, чтобы заменить его в Связке ключей."
            : "Вставьте ваш API-ключ \(provider.title). Он будет сохранён в Связке ключей (Keychain) и никуда больше не передаётся."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = provider.keyPlaceholder
        alert.accessoryView = field
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.set(key, account: provider.id)
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

    @objc private func toggleAutoPaste() {
        let current = UserDefaults.standard.bool(forKey: "autoPaste")
        UserDefaults.standard.set(!current, forKey: "autoPaste")
        rebuildMenu()
    }

    @objc private func toggleSounds() {
        UserDefaults.standard.set(!soundsEnabled, forKey: "sounds")
        rebuildMenu()
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
            showAlert(title: "Не удалось изменить автозапуск", text: error.localizedDescription)
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
