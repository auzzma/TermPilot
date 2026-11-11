import AppKit

struct ScreenSharingKeyStroke: Equatable {
    let key: UInt32
    let down: Bool
}

/// Keeps modifier state in sync even if focus changed while Command was held.
struct ScreenSharingKeyboardState {
    private var modifiers: NSEvent.ModifierFlags = []
    private var heldKeys: [UInt16: UInt32] = [:]
    private static let modifierKeys: [(NSEvent.ModifierFlags, UInt32)] = [
        (.shift, 0xffe1), (.control, 0xffe3), (.option, 0xffe9), (.command, 0xffeb)
    ]

    mutating func updateModifiers(_ flags: NSEvent.ModifierFlags) -> [ScreenSharingKeyStroke] {
        let changes = Self.modifierKeys.compactMap { flag, key -> ScreenSharingKeyStroke? in
            guard modifiers.contains(flag) != flags.contains(flag) else { return nil }
            return ScreenSharingKeyStroke(key: key, down: flags.contains(flag))
        }
        modifiers = flags
        return changes
    }

    mutating func keyDown(code: UInt16, keysym: UInt32?, flags: NSEvent.ModifierFlags) -> [ScreenSharingKeyStroke] {
        var events = updateModifiers(flags)
        if let keysym {
            heldKeys[code] = keysym
            events.append(ScreenSharingKeyStroke(key: keysym, down: true))
        }
        return events
    }

    mutating func keyUp(code: UInt16, flags: NSEvent.ModifierFlags) -> [ScreenSharingKeyStroke] {
        var events: [ScreenSharingKeyStroke] = []
        if let key = heldKeys.removeValue(forKey: code) {
            events.append(ScreenSharingKeyStroke(key: key, down: false))
        }
        events += updateModifiers(flags)
        return events
    }

    mutating func reset() { heldKeys.removeAll(); modifiers = [] }
}
