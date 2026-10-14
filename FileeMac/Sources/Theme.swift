import AppKit
import FileeCore

extension NSColor {
    /// "#rrggbb" or "#rrggbbaa".
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xff) / 255
            g = CGFloat((v >> 16) & 0xff) / 255
            b = CGFloat((v >> 8) & 0xff) / 255
            a = CGFloat(v & 0xff) / 255
        } else {
            r = CGFloat((v >> 16) & 0xff) / 255
            g = CGFloat((v >> 8) & 0xff) / 255
            b = CGFloat(v & 0xff) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// A colour that follows the window's light or dark appearance.
    static func pair(_ light: String, _ dark: String) -> NSColor {
        let l = NSColor(hex: light), d = NSColor(hex: dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        }
    }
}

/// NicAI Design tokens (assets/nicai/tokens.json), light and dark.
enum Theme {
    static let bg = NSColor.pair("#ffffff", "#0b0b0c")
    static let surface = NSColor.pair("#f7f7f8", "#131316")
    static let surface2 = NSColor.pair("#f0f0f2", "#19191d")
    static let line = NSColor.pair("#e4e4e7", "#25252a")
    static let line2 = NSColor.pair("#d2d2d6", "#34343a")
    static let fg = NSColor.pair("#000305", "#ececee")
    static let fg2 = NSColor.pair("#4a4a50", "#c3c3c9")
    static let muted = NSColor.pair("#6b6b70", "#a1a1a8")
    static let accent = NSColor.pair("#e74c3c", "#ff5a47")
    static let accentFill = NSColor(hex: "#d63c2c")
    /// The bar over the active pane: red in light, white in dark.
    static let activeBar = NSColor.pair("#e74c3c", "#ffffff")
    static let accentText = NSColor.pair("#c0392b", "#ff7a6b")
    static let accentSoft = NSColor.pair("#fdeeec", "#2a1512")
    static let success = NSColor.pair("#2f8a3a", "#4cc26b")
    static let warning = NSColor.pair("#d98a00", "#f0ad4e")
    /// Selection in the inactive pane.
    static let selectionInactive = NSColor.pair("#e4e4e7", "#2c2c31")
    static let folderIcon = NSColor.pair("#4a4a50", "#a1a1a8")

    static var settings = Settings()

    /// ⌘+ and ⌘-: each step scales the file lists by 10%.
    static var zoomSteps = 0
    static let zoomRange = -4...8
    static var zoom: CGFloat { pow(1.1, CGFloat(zoomSteps)) }

    static var listSize: CGFloat { (CGFloat(settings.fontSize) * zoom).rounded() }
    static var rowHeight: CGFloat { (listSize * 1.7).rounded() }
    /// A highlight's corner radius (selection, current folder, tab, buttons): `base` at the default cornerRadius of 4,
    /// scaled by settings.json "cornerRadius". 0 draws square corners.
    static func radius(_ base: CGFloat = 4) -> CGFloat { base * CGFloat(settings.cornerRadius) / 4 }

    /// The pane's tab strip: the tab names use the file list's font and size.
    static var tabHeight: CGFloat { max(30, (listSize * 2.1).rounded()) }

    /// The file list font: SF Pro unless settings.json names another one.
    static func listFont(bold: Bool = false, italic: Bool = false, size: CGFloat? = nil) -> NSFont {
        let s = size ?? listSize
        var font: NSFont
        let name = settings.fontName
        if name.isEmpty || name.lowercased() == "system" || name == "SF Pro" {
            font = NSFont.systemFont(ofSize: s, weight: bold ? .semibold : .regular)
        } else {
            font = NSFont(name: name, size: s) ?? NSFont.systemFont(ofSize: s)
            if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        }
        if italic {
            let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            font = NSFont(descriptor: d, size: s) ?? font
        }
        return font
    }

    static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let bold = weight == .bold || weight == .semibold || weight == .heavy || weight == .black
        let name = settings.uiFontName + (bold ? "-Bold" : "-Regular")
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat) -> NSFont { NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
}

/// A plain view with a fill colour that follows the appearance.
final class ColorView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }

    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }
    // Since macOS 14 views don't clip by default: fill the bounds only, never the whole dirty rect.
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

/// A flipped plain view, for manual layout from the top.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = Theme.fg2) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = Theme.ui(size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingMiddle
    l.cell?.truncatesLastVisibleLine = true
    return l
}

/// A flat icon button using an SF Symbol.
func iconButton(_ symbol: String, tip: String, target: AnyObject?, action: Selector) -> NSButton {
    let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: target, action: action)
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.contentTintColor = Theme.muted
    b.toolTip = tip
    b.imageScaling = .scaleProportionallyDown
    b.setButtonType(.momentaryChange)
    return b
}

/// File icons, cached by type: 1 image per extension, per-file icons only for apps and volumes.
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: FileItem) -> NSImage {
        let key: String
        if item.isFolder {
            key = item.kind == .symlink ? "/link" : "/"
        } else if item.isPackage {
            // Apps carry their own icon.
            if let img = cache["pkg:" + item.path] { return img }
            let img = NSWorkspace.shared.icon(forFile: item.path)
            img.size = NSSize(width: 32, height: 32)
            if cache.count < 4000 { cache["pkg:" + item.path] = img }
            return img
        } else {
            key = item.ext
        }
        if let img = cache[key] { return img }
        let img: NSImage
        if item.isFolder {
            img = NSWorkspace.shared.icon(for: .folder)
        } else if let t = UTType(filenameExtension: key), !key.isEmpty {
            img = NSWorkspace.shared.icon(for: t)
        } else {
            img = NSWorkspace.shared.icon(for: .data)
        }
        img.size = NSSize(width: 32, height: 32)
        cache[key] = img
        return img
    }

    private static var customIcons: [String: NSImage?] = [:]

    /// The folder's own icon, else nil: an image in the folder named `.filee-icon.svg` or `.filee-icon.png` (it syncs with the
    /// folder), the Dropbox logo for a folder named Dropbox, else the folder's Finder icon (kHasCustomIcon in the Finder flags).
    /// Cached as a small bitmap. Skipped under /Volumes: network shares can be slow.
    static func customFolderIcon(_ path: String) -> NSImage? {
        if let hit = customIcons[path] { return hit }
        var icon: NSImage?
        if !path.hasPrefix("/Volumes/") {
            var info = [UInt8](repeating: 0, count: 32)
            if let own = folderIconFiles.lazy.compactMap({ NSImage(contentsOfFile: (path as NSString).appendingPathComponent($0)) }).first {
                icon = small(own)
            } else if (path as NSString).lastPathComponent == "Dropbox",
               let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.getdropbox.dropbox") {
                // The folder's own icon is a folder with a small Dropbox mark, unreadable at sidebar size.
                icon = small(NSWorkspace.shared.icon(forFile: app.path))
            } else if getxattr(path, "com.apple.FinderInfo", &info, 32, 0, 0) == 32, info[8] & 0x04 != 0 {
                icon = small(NSWorkspace.shared.icon(forFile: path))
            }
        }
        customIcons[path] = icon
        return icon
    }

    /// A 64 px bitmap of an icon: drawing an app or folder icon as is keeps its large representations in memory.
    static func small(_ image: NSImage, px: Int = 64) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: px / 2, height: px / 2))
        out.addRepresentation(rep)
        return out
    }

    /// A folder's own icon file: the 1st that exists wins.
    static let folderIconFiles = [".filee-icon.svg", ".filee-icon.png"]

    /// The logo for a volume: the image file `volumeIcons` names for it, by its exact name, else by a key its name contains
    /// ("Philips" matches "PHILIPS DVT"). Nil when there is none.
    static func volumeLogo(_ name: String) -> NSImage? {
        let icons = Theme.settings.volumeIcons
        let file = icons[name] ?? icons.first(where: { name.lowercased().contains($0.key.lowercased()) && $0.value.contains("/") })?.value
        guard let file, file.contains("/") else { return nil }
        return NSImage(contentsOfFile: file.expandingHome).map { small($0) }
    }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Volume colours: readable on the light and the dark sidebar.
    static let volumePalette = ["#e74c3c", "#2f80ed", "#2f8a3a", "#d98a00", "#8e44ad", "#16a085", "#d63384", "#5c6bc0", "#c0632b", "#607d8b"]
        .map { NSColor(hex: $0) }

    /// 1 colour per volume name. A name keeps its colour from launch to launch; 2 mounted volumes never share one
    /// while the palette has room.
    static func volumeColours(_ names: [String]) -> [String: NSColor] {
        var taken = Set<Int>()
        var out: [String: NSColor] = [:]
        for name in names.sorted() where out[name] == nil {
            // djb2: String.hashValue changes at every launch.
            var slot = Int(name.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value } % UInt32(volumePalette.count))
            for _ in 0..<volumePalette.count where taken.contains(slot) { slot = (slot + 1) % volumePalette.count }
            taken.insert(slot)
            out[name] = volumePalette[slot]
        }
        return out
    }

    /// The icon for a volume: a logo (an image file in `volumeIcons`), else a symbol:
    /// `volumeIcons` in settings.json first, then a word in the name ("NicVid": film), then the kind of disk
    /// (network share, external, internal).
    static func volumeStyle(path: String, name: String, isLocal: Bool?, isInternal: Bool?, color: NSColor) -> VolumeStyle {
        if path != "/", let logo = volumeLogo(name) { return VolumeStyle(symbol: "externaldrive", color: color, logo: logo) }
        return VolumeStyle(symbol: volumeSymbol(path: path, name: name, isLocal: isLocal, isInternal: isInternal),
                           color: path == "/" ? Theme.folderIcon : color)
    }

    private static func volumeSymbol(path: String, name: String, isLocal: Bool?, isInternal: Bool?) -> String {
        if path == "/" { return "internaldrive" }
        if let s = Theme.settings.volumeIcons[name], symbol(s) != nil { return s }
        let n = name.lowercased()
        let words: [([String], String)] = [
            (["scan"], "doc.viewfinder"),
            (["vid", "movie", "film"], "film"),
            (["mus", "audio", "sound", "podcast"], "music.note"),
            (["photo", "pic", "image", "camera"], "photo"),
            (["backup", "time machine"], "clock.arrow.circlepath"),
            (["doc"], "doc.text"),
            (["download"], "arrow.down.circle"),
            (["personal", "home"], "person.crop.circle"),
        ]
        for (keys, s) in words where keys.contains(where: { n.contains($0) }) { return s }
        if isLocal == false { return "server.rack" }
        if isInternal == true { return "internaldrive" }
        return "externaldrive"
    }
}

/// A volume's sidebar icon: a tinted symbol, or a logo drawn in its own colours.
struct VolumeStyle {
    var symbol: String
    var color: NSColor
    var logo: NSImage? = nil
}

import UniformTypeIdentifiers
