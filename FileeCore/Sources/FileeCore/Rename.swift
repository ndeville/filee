import Foundation
import ImageIO

/// Batch rename: builds the new names, finds conflicts, applies them in 2 steps.
public enum RenameMode: Equatable, Sendable {
    /// 1 base name for all, a number appended: "base_01.jpg". `YYMMDD` in the base becomes each file's date.
    case sequence(base: String)
    case replace(find: String, with: String, regex: Bool, caseSensitive: Bool)
    /// "YYMMDD-" before the name, from the capture date. Names that already start with 6 digits and "-" are left.
    case prefixDate
    case slugify
    case lower, upper, title
}

public struct RenamePlan: Sendable {
    public struct Entry: Sendable, Equatable {
        public var path: String
        public var oldName: String
        public var newName: String
        public var problem: String?

        public init(path: String, oldName: String, newName: String, problem: String? = nil) {
            self.path = path
            self.oldName = oldName
            self.newName = newName
            self.problem = problem
        }
    }

    public init(entries: [Entry]) { self.entries = entries }

    public var entries: [Entry]
    public var isValid: Bool { entries.allSatisfy { $0.problem == nil } && entries.contains { $0.oldName != $0.newName } }
    public var changedCount: Int { entries.filter { $0.oldName != $0.newName }.count }
}

public enum Renamer {
    /// Builds the plan. `paths` are in the pane's sort order; all must be in the same folder for sequence mode
    /// to number them together (other folders still get numbers in their own order).
    /// `dateOf` gives a file's capture date (injectable for tests).
    public static func plan(_ paths: [String], mode: RenameMode,
                            dateOf: (String) -> Date? = CaptureDate.of) -> RenamePlan {
        var entries: [RenamePlan.Entry] = []
        let width = max(2, String(paths.count).count)
        for (i, path) in paths.enumerated() {
            let old = (path as NSString).lastPathComponent
            let (stem, ext) = split(old, isFolder: isFolder(path))
            var newStem = stem
            switch mode {
            case .sequence(let base):
                let b = base.trimmingCharacters(in: .whitespaces)
                let dated = b.contains("YYMMDD") ? b.replacingOccurrences(of: "YYMMDD", with: yymmdd(dateOf(path))) : b
                newStem = paths.count == 1 ? dated : dated + "_" + String(format: "%0\(width)d", i + 1)
            case .replace(let find, let with, let regex, let sensitive):
                newStem = replace(stem, find: find, with: with, regex: regex, caseSensitive: sensitive)
            case .prefixDate:
                if stem.range(of: #"^\d{6}[-_ ]"#, options: .regularExpression) == nil {
                    newStem = yymmdd(dateOf(path)) + "-" + stem
                }
            case .slugify:
                newStem = slug(stem)
            case .lower: newStem = stem.lowercased()
            case .upper: newStem = stem.uppercased()
            case .title: newStem = stem.capitalized
            }
            let newName = ext.isEmpty ? newStem : newStem + "." + ext
            entries.append(.init(path: path, oldName: old, newName: newName, problem: nil))
        }
        return check(entries)
    }

    /// Marks empty names, illegal characters, duplicates in the batch, and clashes with other files in the folder.
    static func check(_ input: [RenamePlan.Entry]) -> RenamePlan {
        var entries = input
        var seen: [String: Int] = [:]
        let renamedAway = Set(entries.map { $0.path.lowercased() })
        for i in entries.indices {
            let e = entries[i]
            let folder = (e.path as NSString).deletingLastPathComponent
            let target = (folder as NSString).appendingPathComponent(e.newName)
            if e.newName.isEmpty || e.newName == "." || e.newName == ".." {
                entries[i].problem = "Empty name"
            } else if e.newName.contains("/") || e.newName.contains(":") {
                entries[i].problem = "Contains / or :"
            } else if e.newName.utf8.count > 255 {
                entries[i].problem = "Name too long"
            } else if let j = seen[target.lowercased()] {
                entries[i].problem = "Same name as \(entries[j].oldName)"
            } else if e.newName != e.oldName, FileManager.default.fileExists(atPath: target),
                      !renamedAway.contains(target.lowercased()) {
                entries[i].problem = "Exists already"
            }
            seen[target.lowercased()] = i
        }
        return RenamePlan(entries: entries)
    }

    /// Applies a valid plan in 2 steps (to temporary names, then to the final ones), so swaps work.
    /// Returns the (from, to) pairs for undo. On failure, already renamed items are put back.
    public static func apply(_ plan: RenamePlan) throws -> [UndoRecord.Pair] {
        let changes = plan.entries.filter { $0.oldName != $0.newName }
        var temps: [(entry: RenamePlan.Entry, temp: String)] = []
        let token = UUID().uuidString.prefix(8)
        do {
            for (i, e) in changes.enumerated() {
                let t = try FileOps.rename(e.path, to: ".filee-rename-\(token)-\(i)")
                temps.append((e, t))
            }
            var done: [UndoRecord.Pair] = []
            for (e, t) in temps {
                let final = try FileOps.rename(t, to: e.newName)
                done.append(.init(e.path, final))
            }
            return done
        } catch {
            // Put every item back under its old name.
            for (e, t) in temps {
                let folder = (e.path as NSString).deletingLastPathComponent
                let current = FileManager.default.fileExists(atPath: t) ? t : (folder as NSString).appendingPathComponent(e.newName)
                _ = try? FileOps.rename(current, to: e.oldName)
            }
            throw error
        }
    }

    // MARK: Pieces

    static func isFolder(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
            && !DirectoryLister.packageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Splits off the extension. Folders and dot files keep their whole name as the stem.
    static func split(_ name: String, isFolder: Bool) -> (String, String) {
        if isFolder { return (name, "") }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[name.index(after: dot)...])
        if ext.isEmpty || ext.contains(" ") || ext.count > 10 { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    public static func yymmdd(_ date: Date?) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd"
        return f.string(from: date ?? Date())
    }

    static func replace(_ s: String, find: String, with: String, regex: Bool, caseSensitive: Bool) -> String {
        guard !find.isEmpty else { return s }
        if regex {
            guard let re = try? NSRegularExpression(pattern: find, options: caseSensitive ? [] : [.caseInsensitive]) else { return s }
            return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
        }
        return s.replacingOccurrences(of: find, with: with, options: caseSensitive ? [] : [.caseInsensitive])
    }

    /// Lower case, accents removed, spaces and "_" to "-", other punctuation dropped, no double "-".
    public static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber || ch == "." {
                out.append(ch)
            } else if ch == " " || ch == "_" || ch == "-" {
                if !out.hasSuffix("-") { out.append("-") }
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        while out.hasPrefix("-") { out.removeFirst() }
        return out
    }
}

/// The date a photo or recording was made: EXIF DateTimeOriginal for images, else the creation date.
public enum CaptureDate {
    public static func of(_ path: String) -> Date? {
        let url = URL(fileURLWithPath: path) as CFURL
        if let src = CGImageSourceCreateWithURL(url, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = f.date(from: s) { return d }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.creationDate] as? Date
    }
}
