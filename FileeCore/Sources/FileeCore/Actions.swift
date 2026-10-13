import Foundation

/// 1 custom action from actions.json (SPEC 5.4).
public struct CustomAction: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case background, terminal }

    public var name: String
    /// Program and arguments. Placeholders: {path} {paths} {dir} {name} {stem}. `~` is expanded.
    public var command: [String]
    /// Lower-case extensions the action applies to. Empty: any file. "/" alone: folders.
    public var extensions: [String]
    public var mode: Mode
    /// Run once per selected item (2 at a time) instead of once for the whole selection.
    public var each: Bool
    public var key: String?
    /// Run through /bin/zsh -lc. Off by default: the command runs directly.
    public var shell: Bool
    /// Refresh the folder when the action ends.
    public var refresh: Bool

    public init(name: String, command: [String], extensions: [String] = [], mode: Mode = .background,
                each: Bool = true, key: String? = nil, shell: Bool = false, refresh: Bool = true) {
        self.name = name
        self.command = command
        self.extensions = extensions
        self.mode = mode
        self.each = each
        self.key = key
        self.shell = shell
        self.refresh = refresh
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        if let arr = try? c.decode([String].self, forKey: .command) {
            command = arr
        } else {
            command = [try c.decode(String.self, forKey: .command)]
        }
        extensions = (try c.decodeIfPresent([String].self, forKey: .extensions) ?? []).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .background
        each = try c.decodeIfPresent(Bool.self, forKey: .each) ?? true
        key = try c.decodeIfPresent(String.self, forKey: .key)
        shell = try c.decodeIfPresent(Bool.self, forKey: .shell) ?? false
        refresh = try c.decodeIfPresent(Bool.self, forKey: .refresh) ?? true
    }

    /// True when the action fits every selected item.
    public func applies(to items: [FileItem]) -> Bool {
        guard !items.isEmpty else { return extensions == ["/"] }
        if extensions.isEmpty { return true }
        return items.allSatisfy { item in
            item.isFolder ? extensions.contains("/") : extensions.contains(item.ext)
        }
    }

    /// The argument lists to run: 1 per item when `each`, else 1 for all. `dir` is the current folder.
    public func invocations(paths: [String], dir: String) -> [[String]] {
        let groups: [[String]] = each ? paths.map { [$0] } : [paths]
        return (groups.isEmpty ? [[]] : groups).map { group in
            var out: [String] = []
            for arg in command {
                if arg == "{paths}" {
                    out.append(contentsOf: group)
                    continue
                }
                let first = group.first ?? dir
                let name = (first as NSString).lastPathComponent
                var a = arg
                a = a.replacingOccurrences(of: "{path}", with: first)
                a = a.replacingOccurrences(of: "{dir}", with: dir)
                a = a.replacingOccurrences(of: "{name}", with: name)
                a = a.replacingOccurrences(of: "{stem}", with: (name as NSString).deletingPathExtension)
                if a.hasPrefix("~/") { a = a.expandingHome }
                out.append(a)
            }
            if shell { return ["/bin/zsh", "-lc", out.joined(separator: " ")] }
            return out
        }
    }
}

public enum DefaultActions {
    /// Examples for a new ~/.filee/actions.json. Add your own scripts there.
    public static let all: [CustomAction] = [
        CustomAction(name: "Open in TextEdit", command: ["/usr/bin/open", "-a", "TextEdit", "{paths}"],
                     extensions: ["txt", "md", "json", "csv", "log"], each: false, refresh: false),
        CustomAction(name: "Compare 2 files (FileMerge)", command: ["/usr/bin/opendiff", "{paths}"], each: false, refresh: false),
        CustomAction(name: "SHA-256 checksum", command: ["/usr/bin/shasum", "-a", "256", "{path}"], refresh: false),
        CustomAction(name: "Make executable", command: ["/bin/chmod", "+x", "{path}"], extensions: ["sh", "py", "command"]),
    ]

    /// The text written to ~/.filee/actions.json on first launch.
    public static var fileText: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let body = (try? enc.encode(all)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return """
        // Filee custom actions (SPEC.md 5.4). Filee reloads this file when you save it.
        // command: program and arguments. Placeholders: {path} {paths} {dir} {name} {stem}. ~ is expanded.
        // extensions: lower-case, without the dot. [] = any file, ["/"] = folders.
        // mode: "background" (status bar shows the result, output in ~/.filee/logs/actions.log) or "terminal" (opens in Ghostty).
        // each: true runs the command once per selected item. key: "ctrl+cmd+u" style, or null.
        // shell: true runs the command through zsh -lc. Filee also copies the selected paths to the clipboard first.

        """ + body + "\n"
    }
}
