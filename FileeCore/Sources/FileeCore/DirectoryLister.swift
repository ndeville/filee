import Darwin
import Foundation

/// Lists a folder with getattrlistbulk(2): 100s of entries per system call, no stat per file.
/// Falls back to FileManager on file systems that don't support it.
public enum DirectoryLister {
    // sys/attr.h. Defined here because the large values don't import cleanly into Swift.
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnCrTime: UInt32 = 0x0000_0200
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnFlags: UInt32 = 0x0004_0000
    private static let cmnAddedTime: UInt32 = 0x1000_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let dirEntryCount: UInt32 = 0x0000_0002
    private static let fileTotalSize: UInt32 = 0x0000_0002
    private static let packInvalAttrs: UInt64 = 0x0000_0008

    private static let vReg: UInt32 = 1
    private static let vDir: UInt32 = 2
    private static let vLnk: UInt32 = 5
    private static let ufHidden: UInt32 = 0x0000_8000

    /// Extensions of folders that macOS shows as 1 file. The listing checks only these, so it never asks
    /// Launch Services about every folder.
    public static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "fcpbundle", "logicx", "band", "rtfd", "pages", "numbers", "key", "xcodeproj",
        "xcworkspace", "playground", "scptd", "wdgt", "prefpane", "qlgenerator", "mdimporter", "saver",
        "appex", "xpc", "nib", "storyboardc", "sparsebundle", "pkg", "mpkg",
        "aplibrary", "theater", "dsym", "xcarchive", "lrlibrary", "lrdata", "workflow", "action",
    ]

    public static func list(_ path: String) throws -> [FileItem] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        do {
            return try bulk(fd: fd, parent: normalised(path))
        } catch let e as POSIXError where e.code == .ENOTSUP || e.code == .EINVAL {
            return try fallback(path)
        }
    }

    static func normalised(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func bulk(fd: Int32, parent: String) throws -> [FileItem] {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = cmnReturnedAttrs | cmnName | cmnError | cmnObjType | cmnCrTime | cmnModTime | cmnFlags | cmnAddedTime
        request.dirattr = dirEntryCount
        request.fileattr = fileTotalSize

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var items: [FileItem] = []
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, packInvalAttrs)
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                if let item = parse(entry + 4, parent: parent) { items.append(item) }
                entry += length
            }
        }
        // Symlinks: 1 stat each to know if the target is a folder. Folders with a package extension: 1 check each.
        for i in items.indices {
            if items[i].kind == .symlink {
                var st = stat()
                if stat(items[i].path, &st) == 0 { items[i].targetIsDirectory = (st.st_mode & S_IFMT) == S_IFDIR }
            } else if items[i].kind == .directory, !items[i].ext.isEmpty {
                items[i].isPackage = isPackage(items[i])
            }
        }
        return items
    }

    private static func parse(_ start: UnsafeMutableRawPointer, parent: String) -> FileItem? {
        var p = start
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size

        // Order: returned attributes, error, then the other common attributes by bit value,
        // then directory or file attributes. FSOPT_PACK_INVAL_ATTRS packs every requested common attribute.
        let error = p.loadUnaligned(as: UInt32.self)
        p += 4
        let nameRef = p.loadUnaligned(as: attrreference_t.self)
        let namePtr = (p + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
        p += MemoryLayout<attrreference_t>.size
        guard returned.commonattr & cmnName != 0 else { return nil }
        let name = String(cString: namePtr)
        let objType = p.loadUnaligned(as: UInt32.self)
        p += 4
        let crtime = p.loadUnaligned(as: timespec.self)
        p += MemoryLayout<timespec>.size
        let modtime = p.loadUnaligned(as: timespec.self)
        p += MemoryLayout<timespec>.size
        let flags = p.loadUnaligned(as: UInt32.self)
        p += 4
        let addedtime = p.loadUnaligned(as: timespec.self)
        p += MemoryLayout<timespec>.size
        // Directory attributes are packed only for folders, file attributes only for the rest.
        var entryCount: UInt32 = 0
        var totalSize: Int64 = 0
        if objType == vDir {
            entryCount = p.loadUnaligned(as: UInt32.self)
        } else {
            totalSize = p.loadUnaligned(as: Int64.self)
        }

        if error != 0 {
            return FileItem(name: name, parent: parent, kind: .other, isHidden: name.hasPrefix("."))
        }
        let kind: FileItem.Kind
        switch objType {
        case vReg: kind = .file
        case vDir: kind = .directory
        case vLnk: kind = .symlink
        default: kind = .other
        }
        func seconds(_ t: timespec) -> Double { Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
        let hasAdded = returned.commonattr & cmnAddedTime != 0
        return FileItem(
            name: name, parent: parent, kind: kind,
            isHidden: name.hasPrefix(".") || (returned.commonattr & cmnFlags != 0 && flags & ufHidden != 0),
            size: kind == .directory ? -1 : (returned.fileattr & fileTotalSize != 0 ? totalSize : 0),
            entryCount: kind == .directory && returned.dirattr & dirEntryCount != 0 ? Int(entryCount) : -1,
            created: returned.commonattr & cmnCrTime != 0 ? seconds(crtime) : 0,
            modified: returned.commonattr & cmnModTime != 0 ? seconds(modtime) : 0,
            added: hasAdded ? seconds(addedtime) : 0
        )
    }

    static func isPackage(_ item: FileItem) -> Bool {
        if packageExtensions.contains(item.ext) { return true }
        // Rare extensions: ask Launch Services once per folder with an extension.
        return (try? item.url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    /// FileManager listing, for file systems without getattrlistbulk.
    static func fallback(_ path: String) throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey, .totalFileSizeKey,
                                      .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys)
        let parent = normalised(path)
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory ?? false
            let isLink = v?.isSymbolicLink ?? false
            var item = FileItem(
                name: url.lastPathComponent, parent: parent,
                kind: isLink ? .symlink : (isDir ? .directory : .file),
                isHidden: v?.isHidden ?? url.lastPathComponent.hasPrefix("."),
                isPackage: v?.isPackage ?? false,
                size: isDir ? -1 : Int64(v?.totalFileSize ?? 0),
                created: v?.creationDate?.timeIntervalSince1970 ?? 0,
                modified: v?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                added: v?.addedToDirectoryDate?.timeIntervalSince1970 ?? 0
            )
            if isLink {
                var isDirTarget: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirTarget) { item.targetIsDirectory = isDirTarget.boolValue }
            }
            return item
        }
    }

    /// Total logical size of a folder, walking it with getattrlistbulk. `cancelled` is checked per folder.
    /// Doesn't follow symlinks or cross into packages' symlinks; does count package contents.
    public static func totalSize(_ path: String, cancelled: () -> Bool = { false }) -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        var stack = [path]
        while let dir = stack.popLast() {
            if cancelled() { break }
            guard let items = try? list(dir) else { continue }
            for item in items {
                switch item.kind {
                case .directory: stack.append(item.path)
                case .file:
                    bytes += max(0, item.size)
                    files += 1
                default: files += 1
                }
            }
        }
        return (bytes, files)
    }
}
