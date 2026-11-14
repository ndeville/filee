import AppKit
import FileeCore

/// The Settings window (⌘,): a toolbar of panes, matching Path Finder's own Settings
/// window (General / Browser / Features / Appearance / Finder). Only General (the
/// default-file-browser toggle) and Finder (hide desktop, quit Finder on launch) have
/// real content today; the rest are placeholders so the toolbar's shape is right.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private var panes: [String: NSView] = [:]
    private var defaultBrowserSwitch: NSSwitch?
    private var hideDesktopSwitch: NSSwitch?
    private var quitFinderSwitch: NSSwitch?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 300))
        window.contentMinSize = NSSize(width: 480, height: 300)
        window.contentMaxSize = NSSize(width: 480, height: 300)
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        if #available(macOS 11.0, *) { window.toolbarStyle = .preference }
        window.toolbar = toolbar
        buildPanes()
        toolbar.selectedItemIdentifier = .init("general")
        window.contentView = panes["general"]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the window, bringing it forward if already open, and refreshes every
    /// toggle from live OS/settings state (another app, or Terminal, may have changed
    /// it while the window was closed).
    func show() {
        defaultBrowserSwitch?.state = FinderIntegration.isDefaultFileViewer() ? .on : .off
        hideDesktopSwitch?.state = FinderIntegration.isDesktopHidden() ? .on : .off
        quitFinderSwitch?.state = Theme.settings.quitFinderOnLaunch ? .on : .off
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Panes

    private func buildPanes() {
        panes["general"] = paneView(title: "Default File Browser", rows: [
            labeledSwitch(
                title: "Set Filee as the default file browser",
                caption: "Other apps' \"Reveal in Finder\" will open Filee instead. macOS still opens Finder "
                    + "for the Dock and for apps that open folders directly — Filee can't fully replace Finder.",
                initial: FinderIntegration.isDefaultFileViewer(),
                store: { self.defaultBrowserSwitch = $0 },
                action: #selector(toggleDefaultBrowser(_:))),
        ])
        panes["finder"] = paneView(title: "Finder", rows: [
            labeledSwitch(
                title: "Hide Finder's Desktop",
                caption: "Removes desktop icons until you turn this back on. Finder quits and reopens to apply the change.",
                initial: FinderIntegration.isDesktopHidden(),
                store: { self.hideDesktopSwitch = $0 },
                action: #selector(toggleHideDesktop(_:))),
            labeledSwitch(
                title: "Quit Finder When Filee Launches",
                caption: "Some macOS features, like Time Machine, may not work correctly while Finder isn't running.",
                initial: Theme.settings.quitFinderOnLaunch,
                store: { self.quitFinderSwitch = $0 },
                action: #selector(toggleQuitFinderOnLaunch(_:))),
        ])
        for id in ["browser", "features", "appearance"] {
            panes[id] = placeholderPane()
        }
    }

    private func paneView(title: String, rows: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 15)
        let stack = NSStackView(views: [heading] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        return container
    }

    private func placeholderPane() -> NSView {
        let label = NSTextField(labelWithString: "Nothing here yet.")
        label.textColor = .secondaryLabelColor
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// 1 switch + title + wrapping caption, stacked. `store` captures the switch so the
    /// controller can read/set its state later (refresh on show, revert on cancel).
    private func labeledSwitch(title: String, caption: String, initial: Bool,
                                store: (NSSwitch) -> Void, action: Selector) -> NSView {
        let toggle = NSSwitch()
        toggle.state = initial ? .on : .off
        toggle.target = self
        toggle.action = action
        store(toggle)
        let titleLabel = NSTextField(labelWithString: title)
        let row = NSStackView(views: [toggle, titleLabel])
        row.orientation = .horizontal
        row.spacing = 8
        let captionLabel = NSTextField(wrappingLabelWithString: caption)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.preferredMaxLayoutWidth = 408
        let column = NSStackView(views: [row, captionLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        return column
    }

    // MARK: Actions

    @objc private func toggleDefaultBrowser(_ sender: NSSwitch) {
        FinderIntegration.setDefaultFileViewer(sender.state == .on)
    }

    @objc private func toggleHideDesktop(_ sender: NSSwitch) {
        guard sender.state == .on else {
            FinderIntegration.setDesktopHidden(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Hide Finder's desktop icons?"
        alert.informativeText = "This quits and reopens Finder. Any open Finder windows will close."
        alert.addButton(withTitle: "Hide Desktop")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            FinderIntegration.setDesktopHidden(true)
        } else {
            sender.state = .off
        }
    }

    @objc private func toggleQuitFinderOnLaunch(_ sender: NSSwitch) {
        AppDelegate.shared.setQuitFinderOnLaunch(sender.state == .on)
    }

    // MARK: NSToolbarDelegate

    private let toolbarInfo: [(String, String, String)] = [
        ("general", "General", "gearshape"),
        ("browser", "Browser", "safari"),
        ("features", "Features", "wrench.and.screwdriver"),
        ("appearance", "Appearance", "paintbrush"),
        ("finder", "Finder", "folder"),
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarInfo.map { .init($0.0) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let info = toolbarInfo.first(where: { $0.0 == identifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = info.1
        item.image = NSImage(systemSymbolName: info.2, accessibilityDescription: info.1)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        window?.contentView = panes[sender.itemIdentifier.rawValue]
    }
}
