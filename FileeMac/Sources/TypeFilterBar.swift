import AppKit
import FileeCore
import UniformTypeIdentifiers

/// The active tab's file-type filter, right of the tabs: All, then the icon of each family's app.
/// A click shows only that family (folders stay); a 2nd click, or All, shows everything again.
final class TypeFilterBar: FlippedView {
    var selected: FileTypeFilter = .all { didSet { refresh() } }
    var onSelect: ((FileTypeFilter) -> Void)?
    private var buttons: [NSButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (i, f) in FileTypeFilter.allCases.enumerated() {
            let b = NSButton(image: Self.image(for: f, size: Theme.tabHeight - 8), target: self, action: #selector(clicked(_:)))
            b.tag = i
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imageScaling = .scaleNone
            b.setButtonType(.momentaryChange)
            b.toolTip = f == .all ? "Show all files" : "Show only \(f.title) files. Folders stay"
            b.wantsLayer = true
            b.layer?.cornerRadius = Theme.radius(5)
            addSubview(b)
            buttons.append(b)
        }
        refresh()
        Self.loadAppIcons { [weak self] in self?.showAppIcons() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Buttons fill the tab strip's height, which follows the file list's font size (⌘+ and ⌘-).
    private var size: CGFloat { Theme.tabHeight - 4 }

    /// Zoom or settings changed: new icon sizes and corners.
    func styleChanged() {
        for (i, f) in FileTypeFilter.allCases.enumerated() {
            buttons[i].image = Self.image(for: f, size: size - 4)
            buttons[i].layer?.cornerRadius = Theme.radius(5)
        }
        needsLayout = true
    }

    private func showAppIcons() {
        for (i, f) in FileTypeFilter.allCases.enumerated() where f != .all {
            buttons[i].image = Self.image(for: f, size: size - 4)
            if let app = Self.appIcons?[f]?.app, !app.isEmpty {
                buttons[i].toolTip = "Show only \(f.title) files (\(app)). Folders stay"
            }
        }
    }

    var width: CGFloat { CGFloat(buttons.count) * (size + 4) - 4 }
    var buttonHeight: CGFloat { buttons.first?.frame.height ?? 0 }

    func button(for f: FileTypeFilter) -> NSButton? {
        FileTypeFilter.allCases.firstIndex(of: f).map { buttons[$0] }
    }

    /// The All symbol. The other buttons stay empty until `loadAppIcons` brings their app's icon.
    private static func image(for f: FileTypeFilter, size: CGFloat) -> NSImage {
        guard f == .all else {
            guard let entry = appIcons?[f] else { return NSImage() }
            guard let image = entry.image else { return badge(for: f, size: size - 2) }
            return NSImage(cgImage: image, size: NSSize(width: size, height: size))
        }
        let img = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "All files") ?? NSImage()
        return img.withSymbolConfiguration(.init(pointSize: (size * 0.6).rounded(), weight: .semibold)) ?? img
    }

    /// Each family's app icon (nil: no app opens it, the badge stands in) and app name, shared by every bar.
    /// Nil until loaded.
    private static var appIcons: [FileTypeFilter: (image: CGImage?, app: String)]?
    private static var waiting: [() -> Void] = []

    /// Looking up the apps and drawing their icons takes about 75 ms: it runs in the background, after launch.
    private static func loadAppIcons(_ done: @escaping () -> Void) {
        if appIcons != nil { return done() }
        waiting.append(done)
        guard waiting.count == 1 else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = findAppIcons()
            DispatchQueue.main.async {
                var icons: [FileTypeFilter: (image: CGImage?, app: String)] = [:]
                for f in FileTypeFilter.allCases where f != .all {
                    icons[f] = found[f].map { ($0.0, $0.1) } ?? (nil, "")
                }
                appIcons = icons
                waiting.forEach { $0() }
                waiting = []
            }
        }
    }

    /// The default app of each family, as a 64 px bitmap of its icon and its name. A family whose default app an
    /// earlier family already shows takes the first installed app of its fallbacks, so 2 buttons never share an icon
    /// (PDF and images both open in Preview). A raw app icon isn't drawn in the window: it decodes 1024 px versions.
    nonisolated private static func findAppIcons() -> [FileTypeFilter: (CGImage, String)] {
        let fallbacks: [FileTypeFilter: [String]] = [
            .pdf: ["com.adobe.Reader", "com.adobe.Acrobat.Pro"],
            .images: ["com.apple.Photos", "com.seriflabs.affinityphoto2", "com.seriflabs.affinityphoto"],
            .video: ["com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX"],
        ]
        let ws = NSWorkspace.shared
        var used: [URL] = []
        var out: [FileTypeFilter: (CGImage, String)] = [:]
        for f in FileTypeFilter.allCases {
            guard let ext = f.sampleExtension, let type = UTType(filenameExtension: ext),
                  var app = ws.urlForApplication(toOpen: type) else { continue }
            if used.contains(app),
               let other = (fallbacks[f] ?? []).lazy.compactMap({ ws.urlForApplication(withBundleIdentifier: $0) })
                   .first(where: { !used.contains($0) }) {
                app = other
            }
            used.append(app)
            let px = 64
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            ws.icon(forFile: app.path).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            if let image = rep.cgImage { out[f] = (image, app.deletingPathExtension().lastPathComponent) }
        }
        return out
    }

    /// A rounded badge in the family's brand colour.
    private static func badge(for f: FileTypeFilter, size side: CGFloat) -> NSImage {
        guard let badge = badges[f] else { return NSImage() }
        let size = NSSize(width: side, height: side)
        let k = side / 17
        return NSImage(size: size, flipped: false) { r in
            NSColor(hex: badge.colour).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            if let symbol = badge.symbol {
                let config = NSImage.SymbolConfiguration(pointSize: 10 * k, weight: .bold).applying(.init(paletteColors: [.white]))
                guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return true }
                img.draw(in: NSRect(x: (r.width - img.size.width) / 2, y: (r.height - img.size.height) / 2,
                                    width: img.size.width, height: img.size.height))
            } else {
                let font = NSFont.systemFont(ofSize: (badge.text.count > 1 ? 6.5 : 10.5) * k, weight: .heavy)
                let text = NSAttributedString(string: badge.text, attributes: [.font: font, .foregroundColor: NSColor.white])
                let t = text.size()
                text.draw(at: NSPoint(x: (r.width - t.width) / 2, y: (r.height - t.height) / 2))
            }
            return true
        }
    }

    private static let badges: [FileTypeFilter: (colour: String, text: String, symbol: String?)] = [
        .pdf: ("#e2231a", "PDF", nil),
        .powerpoint: ("#c43e1c", "P", nil),
        .word: ("#185abd", "W", nil),
        .excel: ("#107c41", "X", nil),
        .markdown: ("#3f3f46", "MD", nil),
        .video: ("#8e44ad", "", "play.fill"),
        .images: ("#0f9d8a", "", "photo.fill"),
    ]

    @objc private func clicked(_ b: NSButton) {
        let f = FileTypeFilter.allCases[b.tag]
        onSelect?(f == selected ? .all : f)
    }

    /// Layer colours are fixed CGColors: set them again when this view's appearance changes (the window's own call
    /// can come before it, and the colours lagged 1 theme switch behind).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// Layer colours are fixed CGColors: also called by Pane.appearanceChanged.
    func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (i, b) in buttons.enumerated() {
                let on = FileTypeFilter.allCases[i] == selected
                b.layer?.backgroundColor = (on ? Theme.accentSoft : NSColor.clear).cgColor
                b.layer?.borderWidth = on ? 1 : 0
                b.layer?.borderColor = Theme.accent.cgColor
                b.alphaValue = on || selected == .all ? 1 : 0.5
                b.contentTintColor = on ? Theme.accentText : Theme.muted
            }
        }
    }

    override func layout() {
        super.layout()
        let s = size
        for (i, b) in buttons.enumerated() {
            b.frame = NSRect(x: CGFloat(i) * (s + 4), y: ((bounds.height - s) / 2).rounded(), width: s, height: s)
        }
    }
}
