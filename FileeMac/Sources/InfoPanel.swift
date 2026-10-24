import AppKit
import AVFoundation
import CoreServices
import FileeCore
import ImageIO

/// Get Info (⌘I): 1 panel for the selection. The main thread shows what 1 stat gives;
/// folder sizes, size on disk, media, Spotlight and Launch Services details fill in from the background.
final class InfoPanel: NSObject {
    static let shared = InfoPanel()

    private let panel = FileePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
    private let text = NSTextView()
    private var generation = 0
    private var token = CancelToken()
    private var title = ""
    private var values: [String: String] = [:]

    /// The rows in the order they show. A row shows once it has a value.
    private static let order = [
        "Items", "Kind", "Where", "Size", "On disk", "Contains",
        "Created", "Modified", "Added", "Last opened",
        "Dimensions", "Video", "Duration", "Pages", "Camera", "Taken", "Version",
        "Opens with", "Tags", "Where from", "Points to", "Permissions", "Flags", "Volume",
    ]
    private static let calculating = "Calculating…"

    override init() {
        super.init()
        panel.title = "Info"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        let scroll = NSScrollView(frame: panel.contentRect(forFrameRect: panel.frame))
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        text.isEditable = false
        text.isRichText = true
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.autoresizingMask = [.width]
        text.backgroundColor = Theme.surface
        panel.contentView = scroll
    }

    func show(_ items: [FileItem]) {
        generation += 1
        token.cancel()
        token = CancelToken()
        values = [:]
        title = items.count == 1 ? items[0].name : "\(items.count.formatted()) items"
        if items.count == 1 { fillOne(items[0]) } else { fillMany(items) }
        render()
        if !panel.isVisible {
            if let w = NSApp.keyWindow { panel.setFrameTopLeftPoint(NSPoint(x: w.frame.maxX - 460, y: w.frame.maxY - 60)) }
            panel.orderFront(nil)
        }
        let gen = generation, token = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadDetails(items, gen: gen, token: token)
        }
    }

    // MARK: Main thread: what the listing and 1 stat give

    private func fillOne(_ it: FileItem) {
        values["Kind"] = Format.kind(it)
        values["Where"] = it.parent.abbreviatingHome
        let attrs = (try? FileManager.default.attributesOfItem(atPath: it.path)) ?? [:]
        if it.kind == .directory {
            values["Size"] = Self.calculating
        } else {
            values["Size"] = "\(Format.size(it.size)) (\(it.size.formatted()) bytes)"
        }
        if let c = attrs[.creationDate] as? Date { values["Created"] = Format.fullDate(c.timeIntervalSince1970) }
        if let m = attrs[.modificationDate] as? Date { values["Modified"] = Format.fullDate(m.timeIntervalSince1970) }
        if it.added > 0 { values["Added"] = Format.fullDate(it.added) }
        if let p = attrs[.posixPermissions] as? Int {
            values["Permissions"] = "\(Self.mode(p, folder: it.kind == .directory)) (\(String(format: "%o", p))) · \(attrs[.ownerAccountName] as? String ?? "")"
        }
        var flags: [String] = []
        if attrs[.immutable] as? Bool == true { flags.append("Locked") }
        if it.isHidden { flags.append("Hidden") }
        if !flags.isEmpty { values["Flags"] = flags.joined(separator: " · ") }
        if it.kind == .symlink, let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: it.path) { values["Points to"] = dest }
    }

    private func fillMany(_ items: [FileItem]) {
        let folders = items.filter { $0.kind == .directory }.count
        values["Items"] = "\(Self.count(items.count - folders, "file")) · \(Self.count(folders, "folder"))"
        let parents = Set(items.map(\.parent))
        if parents.count == 1, let p = parents.first { values["Where"] = p.abbreviatingHome }
        values["Size"] = folders > 0 ? Self.calculating : Format.size(items.reduce(0) { $0 + max(0, $1.size) })
    }

    // MARK: Background

    private func loadDetails(_ items: [FileItem], gen: Int, token: CancelToken) {
        let one = items.count == 1 ? items[0] : nil
        if let one, one.kind != .directory {
            let v = try? one.url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            if let a = v?.totalFileAllocatedSize { post(["On disk": Format.size(Int64(a))], gen) }
        }
        if let one { loadMetadata(one, gen: gen) }

        // Sizes: the files' own sizes plus a walk of each folder.
        guard items.contains(where: { $0.kind == .directory }) else { return }
        var total = DirectoryLister.Usage()
        var looseFiles: [URL] = []
        for it in items where it.kind != .directory {
            total.files += 1
            total.bytes += max(0, it.size)
            looseFiles.append(it.url)
        }
        for url in looseFiles {
            total.allocated += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        let folders = items.filter { $0.kind == .directory }
        total.folders += items.count > 1 ? folders.count : 0
        for f in folders {
            let before = total
            let u = DirectoryLister.usage(f.path, cancelled: { token.isCancelled }, progress: { [weak self] part in
                self?.post(Self.sizeRows(before + part, done: false), gen)
            })
            if token.isCancelled { return }
            total = total + u
        }
        post(Self.sizeRows(total, done: true), gen)
    }

    private static func sizeRows(_ u: DirectoryLister.Usage, done: Bool) -> [String: String] {
        let more = done ? "" : " so far"
        return [
            "Size": "\(Format.size(u.bytes)) (\(u.bytes.formatted()) bytes)\(more)",
            "On disk": Format.size(u.allocated) + more,
            "Contains": "\(count(u.files, "file")) · \(count(u.folders, "folder"))\(more)",
        ]
    }

    private func loadMetadata(_ it: FileItem, gen: Int) {
        let url = it.url
        var rows: [String: String] = [:]
        let v = try? url.resourceValues(forKeys: [.tagNamesKey, .volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let tags = v?.tagNames, !tags.isEmpty { rows["Tags"] = tags.joined(separator: ", ") }
        if let name = v?.volumeLocalizedName {
            rows["Volume"] = v.flatMap(URL.freeSpace).map { "\(name) · \(Format.size($0)) free" } ?? name
        }
        if let md = MDItemCreateWithURL(nil, url as CFURL) {
            if let used = MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date { rows["Last opened"] = Format.fullDate(used.timeIntervalSince1970) }
            if let from = MDItemCopyAttribute(md, kMDItemWhereFroms) as? [String], let first = from.first(where: { !$0.isEmpty }) { rows["Where from"] = first }
        }
        if it.ext == "app", let info = Bundle(url: url)?.infoDictionary {
            let short = info["CFBundleShortVersionString"] as? String
            let build = info["CFBundleVersion"] as? String
            if let short { rows["Version"] = build.map { $0 == short ? short : "\(short) (\($0))" } ?? short }
        }
        if it.kind != .directory, let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            rows["Opens with"] = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        }
        if it.kind == .file {
            rows.merge(Self.imageRows(url)) { $1 }
            if it.ext == "pdf", let doc = CGPDFDocument(url as CFURL) { rows["Pages"] = doc.numberOfPages.formatted() }
        }
        post(rows, gen)
        if ["mp4", "mov", "m4v", "mp3", "wav", "m4a", "aac", "mkv", "aif", "aiff", "flac"].contains(it.ext) {
            Task { [weak self] in
                let rows = await Self.mediaRows(url)
                self?.post(rows, gen)
            }
        }
    }

    private static func imageRows(_ url: URL) -> [String: String] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return [:] }
        var rows = ["Dimensions": "\(w) × \(h) px"]
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let model = (tiff[kCGImagePropertyTIFFModel] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let camera = model.hasPrefix(make) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
            if !camera.isEmpty { rows["Camera"] = camera }
        }
        // EXIF dates read "2026:10:08 14:05:01".
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any], let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String, taken.count >= 16 {
            let day = taken.prefix(10).replacingOccurrences(of: ":", with: "-")
            rows["Taken"] = "\(day) \(taken.dropFirst(11).prefix(5))"
        }
        return rows
    }

    private static func mediaRows(_ url: URL) async -> [String: String] {
        let asset = AVURLAsset(url: url)
        var rows: [String: String] = [:]
        if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
            let s = Int(d.seconds)
            rows["Duration"] = String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let loaded = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions) {
            let (size, transform, fps, formats) = loaded
            let shown = size.applying(transform)
            var parts = ["\(Int(abs(shown.width))) × \(Int(abs(shown.height)))"]
            if fps > 0 { parts.append(fps.rounded() == fps ? "\(Int(fps)) fps" : String(format: "%.2f fps", fps)) }
            if let f = formats.first { parts.append(codecName(CMFormatDescriptionGetMediaSubType(f))) }
            rows["Video"] = parts.joined(separator: " · ")
        }
        return rows
    }

    private static func codecName(_ code: FourCharCode) -> String {
        let s = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? "?"
        switch s {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "av01": return "AV1"
        case "apcn", "apcs", "apco", "apch", "ap4h", "ap4x": return "ProRes"
        default: return s.trimmingCharacters(in: .whitespaces)
        }
    }

    /// "1 file", "1,234 files".
    private static func count(_ n: Int, _ noun: String) -> String { "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")" }

    /// "drwxr-xr-x" from the POSIX mode bits.
    private static func mode(_ p: Int, folder: Bool) -> String {
        let chars = Array("rwxrwxrwx")
        let bits = (0..<9).map { p & (1 << (8 - $0)) != 0 ? chars[$0] : "-" }
        return (folder ? "d" : "-") + String(bits)
    }

    // MARK: Showing

    private func post(_ rows: [String: String], _ gen: Int) {
        guard !rows.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.generation else { return }
            self.values.merge(rows) { $1 }
            self.render()
        }
    }

    private func render() {
        let out = NSMutableAttributedString(string: title + "\n\n", attributes: [.font: Theme.ui(15, weight: .bold), .foregroundColor: Theme.fg])
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 110)]
        para.headIndent = 110
        para.paragraphSpacing = 4
        for k in Self.order {
            guard let v = values[k] else { continue }
            let pending = v == Self.calculating || v.hasSuffix(" so far")
            out.append(NSAttributedString(string: "\(k)\t", attributes: [.font: Theme.ui(12), .foregroundColor: Theme.muted, .paragraphStyle: para]))
            out.append(NSAttributedString(string: "\(v)\n", attributes: [.font: Theme.ui(12.5), .foregroundColor: pending ? Theme.muted : Theme.fg, .paragraphStyle: para]))
        }
        text.textStorage?.setAttributedString(out)
    }

    /// QA: the panel's text.
    var shownText: String { text.string }

    func close() { panel.orderOut(nil) }
}

extension DirectoryLister.Usage {
    static func + (a: Self, b: Self) -> Self {
        var c = a
        c.bytes += b.bytes
        c.allocated += b.allocated
        c.files += b.files
        c.folders += b.folders
        return c
    }
}
