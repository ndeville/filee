import CoreServices
import FileeCore
import Foundation

/// 1 FSEvents stream, at folder granularity, over every folder on screen. A subscriber hears about changes
/// to its own folder's direct content. Folders inside another watched folder share its stream.
final class FolderWatch {
    static let shared = FolderWatch()

    private var stream: FSEventStreamRef?
    private var counts: [String: Int] = [:]
    private var streamRoots: [String] = []
    private var subscribers: [UUID: (folder: String, handler: () -> Void)] = [:]
    private var pendingRestart = false

    /// `folder` must be a canonical path (realpath): FSEvents reports those.
    @discardableResult
    func subscribe(_ folder: String, handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        let f = canonicalPath(folder)
        subscribers[id] = (f, handler)
        counts[f, default: 0] += 1
        let covered = streamRoots.contains { f == $0 || f.hasPrefix($0 == "/" ? "/" : $0 + "/") }
        if counts[f] == 1, !covered { scheduleRestart() }
        return id
    }

    func unsubscribe(_ id: UUID?) {
        guard let id, let sub = subscribers.removeValue(forKey: id) else { return }
        counts[sub.folder, default: 1] -= 1
        if counts[sub.folder] == 0 {
            counts.removeValue(forKey: sub.folder)
            if streamRoots.contains(sub.folder) { scheduleRestart() }
        }
    }

    /// Several subscribe calls in 1 turn of the run loop restart the stream once.
    private func scheduleRestart() {
        guard !pendingRestart else { return }
        pendingRestart = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingRestart = false
            self?.restart()
        }
    }

    private func restart() {
        var since = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        if let s = stream {
            since = FSEventsGetCurrentEventId()
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        var roots: [String] = []
        for p in counts.keys.sorted() where !roots.contains(where: { p == $0 || p.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
            roots.append(p)
        }
        streamRoots = roots
        guard !roots.isEmpty else { return }

        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let hub = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            var changed = Set<String>()
            var rescanAll = false
            for i in 0..<count {
                var p = array[i]
                while p.count > 1, p.hasSuffix("/") { p.removeLast() }
                changed.insert(p)
                if flags[i] & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 { rescanAll = true }
            }
            hub.dispatch(changed, all: rescanAll)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, roots as CFArray, since, 0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    private func dispatch(_ changed: Set<String>, all: Bool) {
        for (_, sub) in subscribers where all || changed.contains(sub.folder) {
            sub.handler()
        }
    }
}
