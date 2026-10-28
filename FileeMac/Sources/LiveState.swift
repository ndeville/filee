import AppKit
import FileeCore

/// The live state for agents: `~/.filee/run/live.json`, read by `filee status` (agent interface, SPEC.md).
/// `state.json` already holds the saved window state, and Filee reloads its config on every change in `~/.filee`
/// itself (FolderWatch reports folders, not files), so the live state sits 1 folder down.
/// Written atomically on a background queue, coalesced to 1 write per run-loop turn.
enum LiveState {
    private static let queue = DispatchQueue(label: "com.nicolasdeville.filee.live", qos: .utility)
    private static let startedAt = Date()
    private static var scheduled = false
    /// The last URL action, echoed with the caller's request id so the CLI can confirm it ran.
    private static var lastAction: [String: Any]?
    static let selectionLimit = 200

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: d)
    }

    static func record(action: String, rid: String?, ok: Bool) {
        lastAction = ["name": action, "rid": rid ?? "", "ok": ok, "at": iso(Date()), "epoch": Date().timeIntervalSince1970]
        publish()
    }

    /// Reveal in Finder: written before Finder opens its window, so a script that sends new Finder windows to Filee
    /// (Hammerspoon on Nic's Mac) can see that Filee asked for this one and leave it alone.
    static func recordNow(action: String) {
        lastAction = ["name": action, "rid": "", "ok": true, "at": iso(Date()), "epoch": Date().timeIntervalSince1970]
        write(now: true)
    }

    /// Ask for a write. Many changes in 1 turn make 1 write.
    static func publish() {
        if scheduled { return }
        scheduled = true
        DispatchQueue.main.async {
            scheduled = false
            write()
        }
    }

    private static func write(now: Bool = false) {
        guard let app = AppDelegate.shared else { return }
        var state: [String: Any] = [
            "pid": Int(getpid()),
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "started_at": iso(startedAt),
            "bundle_path": Bundle.main.bundlePath,
            "updated_at": iso(Date()),
            "windows": app.windows.count,
            "transfers": OperationCenter.shared.running.count,
            "stack": app.state.dropStack,
            "active_path": NSNull(),
            "selection": [String](),
            "selection_count": 0,
            "panes": [Any](),
        ]
        if let w = app.activeWindow, !w.panes.isEmpty {
            let pane = w.activePane
            let sel = pane.fileView == nil ? [] : pane.selectedItems.map(\.path)
            state["active_path"] = pane.path
            state["selection"] = Array(sel.prefix(selectionLimit))
            state["selection_count"] = sel.count
            state["dual_pane"] = w.dualPane
            state["active_pane"] = w.activePaneIndex
            state["panes"] = w.panes.map { p in ["tabs": p.state.tabs.map(\.path), "active_tab": p.state.activeTab] as [String: Any] }
        }
        if let lastAction { state["last_action"] = lastAction }
        let target = app.config.home.appendingPathComponent("run/live.json")
        let save = {
            guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? data.write(to: target, options: .atomic)
        }
        if now { queue.sync(execute: save) } else { queue.async(execute: save) }
    }
}
