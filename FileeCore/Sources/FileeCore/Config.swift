import Foundation

public enum ViewMode: String, Codable, Sendable {
    case list, columns, thumbnails
}

public enum SortKey: String, Codable, Sendable {
    case name, size, modified, kind, added, created, ext, items
}

/// ~/.filee/settings.json. Every field is optional in the file; missing ones take the default.
public struct Settings: Codable, Equatable, Sendable {
    public struct Favourite: Codable, Equatable, Sendable {
        public var name: String
        public var path: String
        public init(_ name: String, _ path: String) {
            self.name = name
            self.path = path
        }
    }

    /// File list font. "" or "System" = SF Pro.
    public var fontName: String
    public var fontSize: Double
    /// Interface font (sidebar, tabs, status bar).
    public var uiFontName: String
    public var favourites: [Favourite]
    /// Jumps: letter after the ⌘J prefix -> folder.
    public var jumps: [String: String]
    public var showHidden: Bool
    public var vimKeys: Bool
    public var defaultView: ViewMode
    public var columns: [String]
    public var newTodayMarker: Bool
    public var terminalApp: String
    public var thumbnailSize: Double
    /// Folders new tabs open in.
    public var newTabPath: String
    /// Sidebar text size. Rows, icons and headings scale with it.
    public var sidebarFontSize: Double
    /// Volume name -> SF Symbol name or image file, to replace the icon Filee picks ("Omarchy": "terminal").
    public var volumeIcons: [String: String]
    /// "rounded" (the macOS window shape) or "square".
    public var windowCorners: String
    /// Radius of the highlights inside the window (selection, current folder, tab, buttons). 0 = square, 4 = default.
    public var cornerRadius: Double

    public init() {
        fontName = "System"
        fontSize = 14
        uiFontName = "Lato"
        favourites = [
            // The home folder by its own name ("nic"), as Finder shows it.
            .init((NSHomeDirectory() as NSString).lastPathComponent, "~"),
            .init("Desktop", "~/Desktop"),
            .init("Documents", "~/Documents"),
            .init("Downloads", "~/Downloads"),
            .init("Applications", "/Applications"),
        ]
        jumps = ["d": "~/Downloads", "h": "~"]
        showHidden = false
        vimKeys = false
        defaultView = .list
        columns = ["name", "size", "modified", "kind"]
        newTodayMarker = true
        terminalApp = "Ghostty"
        thumbnailSize = 160
        newTabPath = "~"
        sidebarFontSize = 14
        volumeIcons = [:]
        windowCorners = "rounded"
        cornerRadius = 4
    }

    public init(from decoder: Decoder) throws {
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? d.fontName
        fontSize = min(28, max(9, try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize))
        uiFontName = try c.decodeIfPresent(String.self, forKey: .uiFontName) ?? d.uiFontName
        favourites = try c.decodeIfPresent([Favourite].self, forKey: .favourites) ?? d.favourites
        jumps = try c.decodeIfPresent([String: String].self, forKey: .jumps) ?? d.jumps
        showHidden = try c.decodeIfPresent(Bool.self, forKey: .showHidden) ?? d.showHidden
        vimKeys = try c.decodeIfPresent(Bool.self, forKey: .vimKeys) ?? d.vimKeys
        defaultView = try c.decodeIfPresent(ViewMode.self, forKey: .defaultView) ?? d.defaultView
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? d.columns
        newTodayMarker = try c.decodeIfPresent(Bool.self, forKey: .newTodayMarker) ?? d.newTodayMarker
        terminalApp = try c.decodeIfPresent(String.self, forKey: .terminalApp) ?? d.terminalApp
        thumbnailSize = min(384, max(64, try c.decodeIfPresent(Double.self, forKey: .thumbnailSize) ?? d.thumbnailSize))
        newTabPath = try c.decodeIfPresent(String.self, forKey: .newTabPath) ?? d.newTabPath
        sidebarFontSize = min(24, max(10, try c.decodeIfPresent(Double.self, forKey: .sidebarFontSize) ?? d.sidebarFontSize))
        volumeIcons = try c.decodeIfPresent([String: String].self, forKey: .volumeIcons) ?? d.volumeIcons
        windowCorners = try c.decodeIfPresent(String.self, forKey: .windowCorners) == "square" ? "square" : d.windowCorners
        cornerRadius = min(10, max(0, try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius))
    }

    public static var fileText: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let body = (try? enc.encode(Settings())).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
        // Filee settings (SPEC.md 8). Filee reloads this file when you save it.
        // fontName: "System" or any installed font, for the file lists. columns: name, size, modified, kind, added, created, ext, items.
        // jumps: ⌘J then the letter goes to the folder. defaultView: list, columns or thumbnails.
        // windowCorners: rounded or square. cornerRadius: 0 (square) to 10, for the highlights inside the window.

        """ + body + "\n"
    }
}

/// 1 tab of a pane.
public struct TabState: Codable, Equatable, Sendable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct PaneState: Codable, Equatable, Sendable {
    public var tabs: [TabState]
    public var activeTab: Int
    public init(tabs: [TabState], activeTab: Int = 0) {
        self.tabs = tabs
        self.activeTab = activeTab
    }
}

/// Per-folder view memory: view, sort.
public struct FolderView: Codable, Equatable, Sendable {
    public var view: ViewMode?
    public var sort: SortKey?
    public var ascending: Bool?
    public var thumbnailSize: Double?
    public init() {}
}

/// ~/.filee/state.json: restored at launch.
public struct AppState: Codable, Equatable, Sendable {
    public var frame: String?
    public var panes: [PaneState]
    public var activePane: Int
    public var dualPane: Bool
    public var sidebarVisible: Bool
    public var sidebarWidth: Double
    public var recent: [String]
    public var dropStack: [String]
    public var folders: [String: FolderView]
    public var zoomSteps: Int
    /// "system", "light" or "dark".
    public var theme: String
    /// Favourites and branches folded in the sidebar tree.
    public var collapsedFavourites: [String]

    public init() {
        frame = nil
        panes = []
        activePane = 0
        dualPane = true
        sidebarVisible = true
        sidebarWidth = 260
        recent = []
        dropStack = []
        folders = [:]
        zoomSteps = 0
        theme = "system"
        collapsedFavourites = []
    }

    public init(from decoder: Decoder) throws {
        let d = AppState()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decodeIfPresent(String.self, forKey: .frame)
        panes = try c.decodeIfPresent([PaneState].self, forKey: .panes) ?? d.panes
        activePane = try c.decodeIfPresent(Int.self, forKey: .activePane) ?? d.activePane
        dualPane = try c.decodeIfPresent(Bool.self, forKey: .dualPane) ?? d.dualPane
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? d.sidebarVisible
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? d.sidebarWidth
        recent = try c.decodeIfPresent([String].self, forKey: .recent) ?? d.recent
        dropStack = try c.decodeIfPresent([String].self, forKey: .dropStack) ?? d.dropStack
        folders = try c.decodeIfPresent([String: FolderView].self, forKey: .folders) ?? d.folders
        zoomSteps = try c.decodeIfPresent(Int.self, forKey: .zoomSteps) ?? d.zoomSteps
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
        collapsedFavourites = try c.decodeIfPresent([String].self, forKey: .collapsedFavourites) ?? d.collapsedFavourites
    }
}

/// The ~/.filee folder (FILEE_HOME moves it). Folder 0700, files 0600.
public final class ConfigStore: @unchecked Sendable {
    public let home: URL
    public var settingsURL: URL { home.appendingPathComponent("settings.json") }
    public var keybindingsURL: URL { home.appendingPathComponent("keybindings.json") }
    public var actionsURL: URL { home.appendingPathComponent("actions.json") }
    public var stateURL: URL { home.appendingPathComponent("state.json") }
    public var logsURL: URL { home.appendingPathComponent("logs") }

    public init(home: URL? = nil) {
        if let home {
            self.home = home
        } else if let env = ProcessInfo.processInfo.environment["FILEE_HOME"], !env.isEmpty {
            self.home = URL(fileURLWithPath: env.expandingHome)
        } else {
            self.home = URL(fileURLWithPath: "~/.filee".expandingHome)
        }
    }

    /// Creates the folder and the default files that don't exist yet.
    public func ensureDefaults(keybindingsText: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: logsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsURL.path)
        let defaults: [(URL, String)] = [
            (settingsURL, Settings.fileText),
            (keybindingsURL, keybindingsText),
            (actionsURL, DefaultActions.fileText),
        ]
        for (url, text) in defaults where !fm.fileExists(atPath: url.path) {
            write(text, to: url)
        }
    }

    public func loadSettings() -> (Settings, String?) {
        guard let data = try? Data(contentsOf: settingsURL) else { return (Settings(), nil) }
        do {
            return (try JSONC.decode(Settings.self, from: data), nil)
        } catch {
            return (Settings(), "settings.json: \(error.localizedDescription)")
        }
    }

    public func loadActions() -> ([CustomAction], String?) {
        guard let data = try? Data(contentsOf: actionsURL) else { return (DefaultActions.all, nil) }
        do {
            return (try JSONC.decode([CustomAction].self, from: data), nil)
        } catch {
            return ([], "actions.json: \(error.localizedDescription)")
        }
    }

    public func loadState() -> AppState {
        guard let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(AppState.self, from: data) else { return AppState() }
        return s
    }

    public func saveState(_ state: AppState) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(state) else { return }
        write(String(decoding: data, as: UTF8.self), to: stateURL)
    }

    /// Atomic write with 0600 permissions.
    public func write(_ text: String, to url: URL) {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        if !FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.moveItem(at: tmp, to: url) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
