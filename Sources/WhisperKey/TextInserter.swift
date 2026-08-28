import AppKit

/// Puts recognized text on the clipboard and, if enabled and permitted,
/// pastes it into the frontmost app by synthesizing Cmd+V.
enum TextInserter {
    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard UserDefaults.standard.bool(forKey: "autoPaste") else { return }
        guard AXIsProcessTrusted() else {
            // Text stays on the clipboard; ask for the permission needed to auto-paste.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return
        }

        // Small delay so the pasteboard settles and hotkey modifiers are released.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let vKey = CGKeyCode(9) // kVK_ANSI_V
            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
            else { return }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
