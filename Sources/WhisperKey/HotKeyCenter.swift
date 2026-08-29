import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).
/// Supports both press and release events, enabling push-to-talk.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Entry {
        let pressed: () -> Void
        let released: (() -> Void)?
    }

    private var entries: [UInt32: Entry] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        pressed: @escaping () -> Void,
        released: (() -> Void)? = nil
    ) -> UInt32? {
        installIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x574B4559) /* 'WKEY' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        entries[id] = Entry(pressed: pressed, released: released)
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        entries.removeValue(forKey: id)
    }

    fileprivate func fire(_ id: UInt32, kind: UInt32) {
        guard let entry = entries[id] else { return }
        switch Int(kind) {
        case kEventHotKeyPressed:
            entry.pressed()
        case kEventHotKeyReleased:
            entry.released?()
        default:
            break
        }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            HotKeyCenter.shared.fire(hkID.id, kind: GetEventKind(event))
            return noErr
        }, 2, &eventTypes, nil, nil)
    }
}

/// A user-selectable hotkey preset. `modifierOnly` presets are a single physical
/// modifier key (e.g. right ⌘) tracked via ModifierKeyMonitor instead of Carbon.
struct HotKeyPreset {
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32
    var modifierOnly: Bool = false

    /// Computed so titles follow the current UI language.
    static var all: [HotKeyPreset] {
        [
            HotKeyPreset(title: "⌥ \(L("key.space"))", keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
            HotKeyPreset(title: "⌃⌥ \(L("key.space"))", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
            HotKeyPreset(title: "⌘⇧ \(L("key.space"))", keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)),
            HotKeyPreset(title: L("key.rightcmd"), keyCode: UInt32(kVK_RightCommand), modifiers: 0, modifierOnly: true),
            HotKeyPreset(title: "F13", keyCode: UInt32(kVK_F13), modifiers: 0),
            HotKeyPreset(title: "F19", keyCode: UInt32(kVK_F19), modifiers: 0),
        ]
    }
}

/// Tracks press/release of a single physical modifier key via NSEvent monitors.
/// Global monitoring of keyboard events needs the Accessibility permission.
final class ModifierKeyMonitor {
    private let keyCode: UInt16
    private let deviceMask: UInt
    private var monitors: [Any] = []
    private var isDown = false

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fired when any regular key is pressed while the modifier is held —
    /// i.e. the user is using it as a normal modifier (⌘C etc.), not push-to-talk.
    var onOtherKeyDown: (() -> Void)?

    /// Device-dependent NSEvent.modifierFlags bits distinguishing left/right keys.
    private static let deviceMasks: [UInt16: UInt] = [
        54: 0x0010, // right ⌘
        55: 0x0008, // left ⌘
        61: 0x0040, // right ⌥
        58: 0x0020, // left ⌥
        62: 0x2000, // right ⌃
    ]

    init?(keyCode: UInt16) {
        guard let mask = Self.deviceMasks[keyCode] else { return nil }
        self.keyCode = keyCode
        self.deviceMask = mask
    }

    func start() {
        stop()
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown],
            handler: { [weak self] event in self?.handle(event) }
        ) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown],
            handler: { [weak self] event in
                self?.handle(event)
                return event
            }
        ) { monitors.append(m) }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            guard event.keyCode == keyCode else { return }
            let pressed = event.modifierFlags.rawValue & deviceMask != 0
            if pressed && !isDown {
                isDown = true
                onPress?()
            } else if !pressed && isDown {
                isDown = false
                onRelease?()
            }
        case .keyDown:
            if isDown { onOtherKeyDown?() }
        default:
            break
        }
    }
}
