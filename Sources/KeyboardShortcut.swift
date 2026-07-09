import AppKit
import Carbon
import Combine

struct KeyboardShortcut: Codable, Equatable {
    static let defaultsKey = "GlobalKeyboardShortcut"
    static let defaultShortcut = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_D),
        carbonModifiers: UInt32(cmdKey | controlKey),
        keyLabel: "D"
    )

    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyLabel: String

    var displayString: String {
        if isHyper {
            return "Hyper + \(keyLabel)"
        }

        var parts: [String] = []
        if hasModifier(cmdKey) { parts.append("Cmd") }
        if hasModifier(optionKey) { parts.append("Opt") }
        if hasModifier(controlKey) { parts.append("Ctrl") }
        if hasModifier(shiftKey) { parts.append("Shift") }
        parts.append(keyLabel)
        return parts.joined(separator: "+")
    }

    private var isHyper: Bool {
        carbonModifiers == UInt32(cmdKey | optionKey | controlKey | shiftKey)
    }

    private func hasModifier(_ modifier: Int) -> Bool {
        carbonModifiers & UInt32(modifier) != 0
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let carbonModifiers = KeyboardShortcut.carbonModifiers(from: event.modifierFlags)
        guard carbonModifiers != 0 else { return nil }

        let keyLabel = KeyboardShortcut.keyLabel(for: event)
        guard !keyLabel.isEmpty else { return nil }

        self.init(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: carbonModifiers,
            keyLabel: keyLabel
        )
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    private static func keyLabel(for event: NSEvent) -> String {
        if let known = keyLabelsByCode[event.keyCode] {
            return known
        }

        if let characters = event.charactersIgnoringModifiers,
           let firstCharacter = characters.first,
           !firstCharacter.isWhitespace {
            return String(firstCharacter).uppercased()
        }

        return "Key \(event.keyCode)"
    }

    private static let keyLabelsByCode: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A",
        UInt16(kVK_ANSI_B): "B",
        UInt16(kVK_ANSI_C): "C",
        UInt16(kVK_ANSI_D): "D",
        UInt16(kVK_ANSI_E): "E",
        UInt16(kVK_ANSI_F): "F",
        UInt16(kVK_ANSI_G): "G",
        UInt16(kVK_ANSI_H): "H",
        UInt16(kVK_ANSI_I): "I",
        UInt16(kVK_ANSI_J): "J",
        UInt16(kVK_ANSI_K): "K",
        UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M",
        UInt16(kVK_ANSI_N): "N",
        UInt16(kVK_ANSI_O): "O",
        UInt16(kVK_ANSI_P): "P",
        UInt16(kVK_ANSI_Q): "Q",
        UInt16(kVK_ANSI_R): "R",
        UInt16(kVK_ANSI_S): "S",
        UInt16(kVK_ANSI_T): "T",
        UInt16(kVK_ANSI_U): "U",
        UInt16(kVK_ANSI_V): "V",
        UInt16(kVK_ANSI_W): "W",
        UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y",
        UInt16(kVK_ANSI_Z): "Z",
        UInt16(kVK_ANSI_0): "0",
        UInt16(kVK_ANSI_1): "1",
        UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3",
        UInt16(kVK_ANSI_4): "4",
        UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6",
        UInt16(kVK_ANSI_7): "7",
        UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",
        UInt16(kVK_ANSI_Minus): "-",
        UInt16(kVK_ANSI_Equal): "=",
        UInt16(kVK_ANSI_LeftBracket): "[",
        UInt16(kVK_ANSI_RightBracket): "]",
        UInt16(kVK_ANSI_Backslash): "\\",
        UInt16(kVK_ANSI_Semicolon): ";",
        UInt16(kVK_ANSI_Quote): "'",
        UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Period): ".",
        UInt16(kVK_ANSI_Slash): "/",
        UInt16(kVK_ANSI_Grave): "`",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Return): "Return",
        UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Delete): "Delete",
        UInt16(kVK_ForwardDelete): "Forward Delete",
        UInt16(kVK_Escape): "Esc",
        UInt16(kVK_LeftArrow): "Left",
        UInt16(kVK_RightArrow): "Right",
        UInt16(kVK_UpArrow): "Up",
        UInt16(kVK_DownArrow): "Down",
        UInt16(kVK_Home): "Home",
        UInt16(kVK_End): "End",
        UInt16(kVK_PageUp): "Page Up",
        UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_F1): "F1",
        UInt16(kVK_F2): "F2",
        UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7",
        UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11",
        UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13",
        UInt16(kVK_F14): "F14",
        UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17",
        UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19",
        UInt16(kVK_F20): "F20"
    ]
}

final class GlobalShortcutSettings: ObservableObject {
    static let shared = GlobalShortcutSettings()

    @Published private(set) var shortcut: KeyboardShortcut

    private init() {
        shortcut = Self.loadShortcut()
    }

    func save(_ shortcut: KeyboardShortcut) {
        self.shortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: KeyboardShortcut.defaultsKey)
        }
    }

    private static func loadShortcut() -> KeyboardShortcut {
        guard let data = UserDefaults.standard.data(forKey: KeyboardShortcut.defaultsKey),
              let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) else {
            return .defaultShortcut
        }
        return shortcut
    }
}
