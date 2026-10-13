import Foundation

/// One key press with its modifiers, in VS Code notation: "shift+cmd+f".
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public var cmd = false
    public var shift = false
    public var alt = false
    public var ctrl = false
    public var key: String

    public init(key: String, cmd: Bool = false, shift: Bool = false, alt: Bool = false, ctrl: Bool = false) {
        self.key = key
        self.cmd = cmd
        self.shift = shift
        self.alt = alt
        self.ctrl = ctrl
    }

    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" style: an empty last part means the key is "+".
        var key = ""
        var mods = parts
        if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            key = "+"
            mods = Array(parts.dropLast(2))
        } else {
            key = parts.last ?? ""
            mods = Array(parts.dropLast())
        }
        guard !key.isEmpty else { return nil }
        self.key = Self.normalise(key)
        for m in mods {
            switch m {
            case "cmd", "meta", "command": cmd = true
            case "shift": shift = true
            case "alt", "option", "opt": alt = true
            case "ctrl", "control": ctrl = true
            default: return nil
            }
        }
    }

    static func normalise(_ key: String) -> String {
        switch key {
        case "return": return "enter"
        case "esc": return "escape"
        case "del": return "delete"
        case "backspace": return "backspace"
        case "arrowup": return "up"
        case "arrowdown": return "down"
        case "arrowleft": return "left"
        case "arrowright": return "right"
        default: return key
        }
    }

    public var description: String {
        var s = ""
        if ctrl { s += "ctrl+" }
        if shift { s += "shift+" }
        if alt { s += "alt+" }
        if cmd { s += "cmd+" }
        return s + key
    }

    /// The symbol form for menus and the palette: ⌃⌥⇧⌘K.
    public var symbols: String {
        var s = ""
        if ctrl { s += "⌃" }
        if alt { s += "⌥" }
        if shift { s += "⇧" }
        if cmd { s += "⌘" }
        let names: [String: String] = [
            "enter": "↩", "escape": "⎋", "tab": "⇥", "up": "↑", "down": "↓", "left": "←", "right": "→",
            "backspace": "⌫", "delete": "⌦", "space": "Space",
        ]
        return s + (names[key] ?? key.uppercased())
    }
}

public struct KeyBinding: Equatable, Sendable {
    public var chords: [KeyChord]
    public var command: String
    public var args: String?

    public init(chords: [KeyChord], command: String, args: String? = nil) {
        self.chords = chords
        self.command = command
        self.args = args
    }

    public var symbols: String { chords.map(\.symbols).joined(separator: " ") }
}

public enum KeybindingParser {
    /// Parses a VS Code style keybindings file. Entries with a "-" command remove an earlier binding.
    public static func parse(_ data: Data, defaults: [KeyBinding] = []) -> (bindings: [KeyBinding], errors: [String]) {
        var result = defaults
        var errors: [String] = []
        guard let arr = (try? JSONC.object(from: data)) as? [[String: Any]] else {
            return (defaults, ["keybindings.json isn't a valid JSON array"])
        }
        for entry in arr {
            guard let key = entry["key"] as? String, let command = entry["command"] as? String else { continue }
            let chords = key.split(separator: " ").compactMap { KeyChord(String($0)) }
            guard !chords.isEmpty, chords.count == key.split(separator: " ").count else {
                errors.append("Unknown key: \(key)")
                continue
            }
            var args: String?
            if let a = entry["args"] {
                if let s = a as? String { args = s }
                else if let d = a as? [String: Any], let snip = d["snippet"] as? String { args = snip }
                else if let d = a as? [String: Any], let text = d["text"] as? String { args = text }
                else if let d = a as? [String: Any], let path = d["path"] as? String { args = path }
            }
            if command.hasPrefix("-") {
                let name = String(command.dropFirst())
                result.removeAll { $0.command == name && $0.chords == chords }
            } else {
                result.removeAll { $0.chords == chords }
                result.append(KeyBinding(chords: chords, command: command, args: args))
            }
        }
        return (result, errors)
    }
}
