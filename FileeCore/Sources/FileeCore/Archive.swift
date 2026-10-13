import Foundation

/// Zip only (decision 26), through /usr/bin/ditto: the same format Finder writes.
public enum Archive {
    /// Zips `paths` (all in the same folder) next to them. 1 item: "<name>.zip"; several: "Archive.zip".
    /// Returns the zip's path.
    public static func compress(_ paths: [String]) throws -> String {
        guard let first = paths.first else { throw OperationError.failed("zip", "nothing selected") }
        let folder = (first as NSString).deletingLastPathComponent
        let base = paths.count == 1 ? (first as NSString).lastPathComponent + ".zip" : "Archive.zip"
        let zip = (folder as NSString).appendingPathComponent(FileOps.uniqueName(base, in: folder))
        if paths.count == 1 {
            try run(["-c", "-k", "--sequesterRsrc", "--keepParent", first, zip])
            return zip
        }
        // Several items: ditto zips 1 source, so they go into a temporary "Archive" folder first, as clones
        // where the volume allows (no extra space on APFS).
        let stage = (NSTemporaryDirectory() as NSString).appendingPathComponent("filee-zip-\(UUID().uuidString)")
        let inner = (stage as NSString).appendingPathComponent("Archive")
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: stage) }
        for p in paths {
            try FileOps.copyItem(p, to: (inner as NSString).appendingPathComponent((p as NSString).lastPathComponent))
        }
        try run(["-c", "-k", "--sequesterRsrc", inner, zip])
        return zip
    }

    /// Extracts a zip into a new folder named after it, next to it. Returns the folder's path.
    public static func extract(_ zip: String) throws -> String {
        let folder = (zip as NSString).deletingLastPathComponent
        let name = ((zip as NSString).lastPathComponent as NSString).deletingPathExtension
        let target = (folder as NSString).appendingPathComponent(FileOps.uniqueName(name, in: folder))
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
        do {
            try run(["-x", "-k", zip, target])
        } catch {
            try? FileManager.default.removeItem(atPath: target)
            throw error
        }
        // A zip that holds 1 folder of the same name: lift its content up 1 level.
        if let items = try? FileManager.default.contentsOfDirectory(atPath: target).filter({ $0 != "__MACOSX" && $0 != ".DS_Store" }),
           items.count == 1 {
            let inner = (target as NSString).appendingPathComponent(items[0])
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: inner, isDirectory: &isDir), isDir.boolValue, items[0] == name {
                let tmp = target + ".filee-tmp"
                try FileManager.default.moveItem(atPath: inner, toPath: tmp)
                try FileManager.default.removeItem(atPath: target)
                try FileManager.default.moveItem(atPath: tmp, toPath: target)
            }
        }
        try? FileManager.default.removeItem(atPath: (target as NSString).appendingPathComponent("__MACOSX"))
        return target
    }

    static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw OperationError.failed("ditto", msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
