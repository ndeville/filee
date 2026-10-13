import Foundation
import UniformTypeIdentifiers

public enum Format {
    /// Base-2 sizes, as Path Finder shows them: "512 B", "1.2 KB", "34.5 MB", "1.07 GB".
    public static func size(_ bytes: Int64) -> String {
        if bytes < 0 { return "--" }
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1024
        var i = 0
        while value >= 1024, i < units.count - 1 {
            value /= 1024
            i += 1
        }
        let digits = value >= 100 ? 0 : (value >= 10 ? 1 : (i >= 2 ? 2 : 1))
        return String(format: "%.\(digits)f %@", value, units[i])
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let fullFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// "today 14:05", "yesterday 09:12", "3 days ago", else "2026-10-08 14:05". 24-hour clock.
    public static func date(_ seconds: Double, now: Date = Date()) -> String {
        guard seconds > 0 else { return "--" }
        let d = Date(timeIntervalSince1970: seconds)
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let day = cal.startOfDay(for: d)
        let days = cal.dateComponents([.day], from: day, to: today).day ?? 99
        switch days {
        case 0: return "today \(timeFormat.string(from: d))"
        case 1: return "yesterday \(timeFormat.string(from: d))"
        case 2...6: return "\(days) days ago"
        default: return fullFormat.string(from: d)
        }
    }

    public static func fullDate(_ seconds: Double) -> String {
        seconds > 0 ? fullFormat.string(from: Date(timeIntervalSince1970: seconds)) : "--"
    }

    nonisolated(unsafe) private static var kindCache: [String: String] = [:]
    private static let kindLock = NSLock()

    /// "Folder", "PDF document", "Markdown". Cached per extension.
    public static func kind(_ item: FileItem) -> String {
        if item.isFolder { return item.kind == .symlink ? "Folder (link)" : "Folder" }
        if item.kind == .symlink { return "Symlink" }
        let ext = item.ext
        if ext.isEmpty { return item.isPackage ? "Package" : "Document" }
        kindLock.lock()
        defer { kindLock.unlock() }
        if let k = kindCache[ext] { return k }
        let k = UTType(filenameExtension: ext)?.localizedDescription?.capitalizedFirst ?? ext.uppercased() + " file"
        kindCache[ext] = k
        return k
    }

    /// "1 item", "12 items".
    public static func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count.formatted()) items" }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Finder-like name order without ICU collation: case and accents ignored, digit runs compared as numbers
/// ("file 2" before "file 10"). Keys are built once per item, so 10,000 names sort in a few ms.
public enum NaturalOrder {
    public static func key(_ s: String) -> [UInt8] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).utf8)
    }

    /// -1, 0 or 1.
    public static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let ca = a[i], cb = b[j]
            if isDigit(ca), isDigit(cb) {
                // Skip leading zeros, then the longer run is the larger number.
                var si = i, sj = j
                while si < a.count, a[si] == 48 { si += 1 }
                while sj < b.count, b[sj] == 48 { sj += 1 }
                var ei = si, ej = sj
                while ei < a.count, isDigit(a[ei]) { ei += 1 }
                while ej < b.count, isDigit(b[ej]) { ej += 1 }
                let la = ei - si, lb = ej - sj
                if la != lb { return la < lb ? -1 : 1 }
                var k = 0
                while k < la {
                    if a[si + k] != b[sj + k] { return a[si + k] < b[sj + k] ? -1 : 1 }
                    k += 1
                }
                i = ei
                j = ej
                continue
            }
            if ca != cb { return ca < cb ? -1 : 1 }
            i += 1
            j += 1
        }
        if a.count - i == b.count - j { return 0 }
        return a.count - i < b.count - j ? -1 : 1
    }

    @inline(__always) private static func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
}
