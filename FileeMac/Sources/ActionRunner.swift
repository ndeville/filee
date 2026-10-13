import AppKit
import FileeCore

/// Runs custom actions from actions.json (SPEC 5.4). Never on its own: only from a key, the palette or a menu.
final class ActionRunner {
    static let shared = ActionRunner()

    private(set) var actions: [CustomAction] = []
    private let queue = DispatchQueue(label: "filee.actions", qos: .userInitiated, attributes: .concurrent)

    func load(_ actions: [CustomAction]) {
        self.actions = actions
        Keymap.shared.actionBindings = actions.compactMap { a in
            guard let key = a.key else { return nil }
            let chords = key.split(separator: " ").compactMap { KeyChord(String($0)) }
            return chords.isEmpty ? nil : KeyBinding(chords: chords, command: "action:" + a.name, args: a.name)
        }
    }

    func actions(for items: [FileItem]) -> [CustomAction] {
        actions.filter { $0.applies(to: items) }
    }

    func run(named name: String, in browser: BrowserWindowController) {
        guard let action = actions.first(where: { $0.name == name }) else {
            browser.showMessage("❌ No action named “\(name)”", error: true)
            return
        }
        let pane = browser.activePane
        var items = pane.selectedItems
        // Folder actions with nothing selected act on the current folder.
        if items.isEmpty, action.extensions == ["/"] { items = pane.selectedOrFolder }
        guard action.applies(to: items) else {
            browser.showMessage("“\(name)” doesn't apply to this selection", error: true)
            return
        }
        let paths = items.map(\.path)
        // Older scripts read the clipboard: put the paths there first.
        Clipboard.board.clearContents()
        Clipboard.board.setString(paths.joined(separator: "\n"), forType: .string)
        let calls = action.invocations(paths: paths, dir: pane.targetFolder)
        log("▶ \(action.name) on \(paths.count) item(s)")
        switch action.mode {
        case .terminal: runInTerminal(calls, action: action, browser: browser)
        case .background: runInBackground(calls, action: action, browser: browser, folder: pane.targetFolder)
        }
    }

    private func runInBackground(_ calls: [[String]], action: CustomAction, browser: BrowserWindowController, folder: String) {
        browser.showMessage("⏳ \(action.name)…")
        let group = DispatchGroup()
        let limit = DispatchSemaphore(value: 2)
        let lock = NSLock()
        var failures: [String] = []
        for argv in calls {
            group.enter()
            queue.async { [weak self] in
                limit.wait()
                defer {
                    limit.signal()
                    group.leave()
                }
                let (status, output) = Self.execute(argv)
                self?.log("$ \(argv.joined(separator: " "))\n\(output)\n→ exit \(status)")
                if status != 0 {
                    lock.lock()
                    failures.append(output.split(separator: "\n").last.map(String.init) ?? "exit \(status)")
                    lock.unlock()
                }
            }
        }
        group.notify(queue: .main) { [weak browser] in
            if failures.isEmpty {
                browser?.showMessage("✅ \(action.name): done (\(calls.count))")
            } else {
                browser?.showMessage("❌ \(action.name): \(failures.count) of \(calls.count) failed · \(failures[0]) · see ~/.filee/logs/actions.log", error: true)
            }
            if action.refresh { OperationCenter.shared.touched([folder]) }
        }
    }

    /// Runs 1 command, returns the exit status and the combined output. No shell unless the action asked.
    static func execute(_ argv: [String]) -> (Int32, String) {
        guard let exe = argv.first else { return (127, "empty command") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        // ~/.zshenv's PYTHONPATH shadows packages in Nic's scripts.
        env.removeValue(forKey: "PYTHONPATH")
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return (127, "can't run \(exe): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        return (p.terminationStatus, String(out.suffix(4000)))
    }

    /// Terminal actions: a small script in ~/.filee/logs runs the command in Ghostty, then waits for a key.
    private func runInTerminal(_ calls: [[String]], action: CustomAction, browser: BrowserWindowController) {
        let lines = calls.map { argv in argv.map(Self.shellQuote).joined(separator: " ") }
        let script = """
        #!/bin/zsh
        unset PYTHONPATH
        echo "▶ \(action.name.replacingOccurrences(of: "\"", with: ""))"
        \(lines.joined(separator: "\n"))
        echo
        echo "✅ Done. Press Return to close."
        read
        """
        let dir = AppDelegate.shared.config.logsURL
        let url = dir.appendingPathComponent("run-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            browser.showMessage("❌ \(error.localizedDescription)", error: true)
            return
        }
        let ghostty = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
        if let ghostty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-na", ghostty.path, "--args", "-e", url.path]
            try? p.run()
        } else {
            NSWorkspace.shared.open(url)
        }
        browser.showMessage("▶ \(action.name) runs in Ghostty")
        // Scripts are removed after a day.
        cleanOldScripts(in: dir)
    }

    private func cleanOldScripts(in dir: URL) {
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-86400)
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where f.pathExtension == "command" {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < old { try? fm.removeItem(at: f) }
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private let logLock = NSLock()

    func log(_ text: String) {
        logLock.lock()
        defer { logLock.unlock() }
        let url = AppDelegate.shared.config.logsURL.appendingPathComponent("actions.log")
        let line = "[\(Format.fullDate(Date().timeIntervalSince1970))] \(text)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}
