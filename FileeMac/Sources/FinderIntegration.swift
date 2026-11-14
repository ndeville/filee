import AppKit

/// Wraps the Terminal commands README.md documents for "make Filee the default file
/// viewer" and Path Finder's "hide Finder's desktop" / "quit Finder" toggles.
enum FinderIntegration {
    static var filleeBundleID: String { Bundle.main.bundleIdentifier ?? "com.nicolasdeville.filee" }

    static func isDefaultFileViewer() -> Bool {
        defaultsRead(["read", "-g", "NSFileViewer"]) == filleeBundleID
    }

    static func setDefaultFileViewer(_ on: Bool) {
        if on {
            defaultsRun(["write", "-g", "NSFileViewer", filleeBundleID])
        } else {
            defaultsRun(["delete", "-g", "NSFileViewer"])
        }
    }

    static func isDesktopHidden() -> Bool {
        defaultsRead(["read", "com.apple.finder", "CreateDesktop"]) == "0"
    }

    static func setDesktopHidden(_ hidden: Bool) {
        defaultsRun(["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"])
        relaunchFinder()
    }

    static func quitFinder() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.terminate()
    }

    private static func relaunchFinder() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Finder"]
        try? p.run()
        p.waitUntilExit()
    }

    /// Returns stdout trimmed, or nil if the key isn't set / the command failed.
    private static func defaultsRead(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func defaultsRun(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
