import Foundation

/// 1 entry of a folder listing. Dates are seconds since 1970; 0 means unknown.
public struct FileItem: Hashable, Sendable {
    public enum Kind: UInt8, Sendable {
        case file, directory, symlink, other
    }

    public var name: String
    /// The folder that holds the item, without a trailing slash (except "/").
    public var parent: String
    public var kind: Kind
    public var isHidden: Bool
    /// A directory shown as 1 file: .app, .bundle, .photoslibrary and others.
    public var isPackage: Bool
    /// For a symlink: the target is a folder.
    public var targetIsDirectory: Bool
    /// Logical size in bytes. -1 for a folder until its size is calculated.
    public var size: Int64
    /// Folders: number of entries, -1 when unknown.
    public var entryCount: Int
    public var created: Double
    public var modified: Double
    public var added: Double

    public init(name: String, parent: String, kind: Kind, isHidden: Bool = false, isPackage: Bool = false,
                targetIsDirectory: Bool = false, size: Int64 = 0, entryCount: Int = -1,
                created: Double = 0, modified: Double = 0, added: Double = 0) {
        self.name = name
        self.parent = parent
        self.kind = kind
        self.isHidden = isHidden
        self.isPackage = isPackage
        self.targetIsDirectory = targetIsDirectory
        self.size = size
        self.entryCount = entryCount
        self.created = created
        self.modified = modified
        self.added = added
    }

    public var path: String { parent == "/" ? "/" + name : parent + "/" + name }
    public var url: URL { URL(fileURLWithPath: path) }

    /// A folder the user can enter: a real folder (not a package) or a symlink to one.
    public var isFolder: Bool {
        (kind == .directory && !isPackage) || (kind == .symlink && targetIsDirectory)
    }

    public var ext: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    public var stem: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// Date added, else creation date.
    public var addedOrCreated: Double { added > 0 ? added : created }

    /// Added to its folder on or after `dayStart` (local midnight).
    public func isNew(since dayStart: Double) -> Bool { addedOrCreated >= dayStart }
}

public extension String {
    /// "/Users/me/x" -> "~/x".
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
    /// "~/x" -> "/Users/me/x".
    var expandingHome: String { (self as NSString).expandingTildeInPath }
}

/// Local midnight of the day that holds `date`.
public func startOfDay(_ date: Date = Date()) -> Double {
    Calendar.current.startOfDay(for: date).timeIntervalSince1970
}

/// realpath(3): symlinks and "/private" resolved, as FSEvents reports paths.
public func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
