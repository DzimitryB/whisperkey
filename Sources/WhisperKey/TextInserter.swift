import AppKit

/// Puts recognized text on the clipboard and, if enabled and permitted,
/// pastes it into the frontmost app by synthesizing Cmd+V.
enum TextInserter {
    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Auto-paste needs Accessibility; without it the text silently stays on the
        // clipboard — no spontaneous permission prompts (asked only when the user
        // enables the toggle in the menu).
        guard UserDefaults.standard.bool(forKey: "autoPaste"), AXIsProcessTrusted() else { return }

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
