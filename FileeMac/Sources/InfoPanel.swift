import AppKit
import AVFoundation
import FileeCore
import ImageIO

/// Get Info (⌃⌘I): 1 panel for the selection. Folder sizes and media details fill in as they arrive.
final class InfoPanel: NSObject {
    static let shared = InfoPanel()

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
    private let text = NSTextView()
    private var generation = 0

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
        let gen = generation
        var rows: [(String, String)] = []
        if items.count == 1 {
            let it = items[0]
            rows = [("Name", it.name), ("Where", it.parent.abbreviatingHome), ("Kind", Format.kind(it))]
            if it.kind != .directory { rows.append(("Size", "\(Format.size(it.size)) (\(it.size.formatted()) bytes)")) }
            let attrs = (try? FileManager.default.attributesOfItem(atPath: it.path)) ?? [:]
            if let c = attrs[.creationDate] as? Date { rows.append(("Created", Format.fullDate(c.timeIntervalSince1970))) }
            if let m = attrs[.modificationDate] as? Date { rows.append(("Modified", Format.fullDate(m.timeIntervalSince1970))) }
            if let added = try? it.url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate {
                rows.append(("Added", Format.fullDate(added.timeIntervalSince1970)))
            }
            if let p = attrs[.posixPermissions] as? Int { rows.append(("Permissions", String(format: "%o", p) + " · " + (attrs[.ownerAccountName] as? String ?? ""))) }
            if it.kind == .symlink, let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: it.path) { rows.append(("Points to", dest)) }
            if let dims = imageSize(it.path) { rows.append(("Dimensions", dims)) }
        } else {
            let files = items.filter { $0.kind != .directory }
            rows = [("Items", "\(items.count) (\(items.count - files.count) folders)"),
                    ("Files size", Format.size(files.reduce(0) { $0 + $1.size }))]
        }
        render(rows, title: items.count == 1 ? items[0].name : "\(items.count) items")
        if !panel.isVisible {
            if let w = NSApp.keyWindow { panel.setFrameTopLeftPoint(NSPoint(x: w.frame.maxX - 440, y: w.frame.maxY - 60)) }
            panel.orderFront(nil)
        }
        // Slow parts in the background: folder sizes, media duration.
        let folders = items.filter { $0.kind == .directory }.map(\.path)
        let media = items.count == 1 && ["mp4", "mov", "m4v", "mp3", "wav", "m4a", "aac", "mkv"].contains(items[0].ext) ? items[0].url : nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var extra: [(String, String)] = []
            if !folders.isEmpty {
                var bytes: Int64 = 0, files = 0
                for f in folders {
                    let t = DirectoryLister.totalSize(f)
                    bytes += t.bytes
                    files += t.files
                }
                extra.append(("Folder size", "\(Format.size(bytes)) · \(files.formatted()) files"))
            }
            let finish = { (more: [(String, String)]) in
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    rows += more
                    self.render(rows, title: items.count == 1 ? items[0].name : "\(items.count) items")
                }
            }
            if let media {
                Task {
                    let asset = AVURLAsset(url: media)
                    if let d = try? await asset.load(.duration), d.seconds.isFinite {
                        let s = Int(d.seconds)
                        extra.append(("Duration", String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)))
                    }
                    finish(extra)
                }
            } else {
                finish(extra)
            }
        }
    }

    private func imageSize(_ path: String) -> String? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(w) × \(h) px"
    }

    private func render(_ rows: [(String, String)], title: String) {
        let out = NSMutableAttributedString(string: title + "\n\n", attributes: [.font: Theme.ui(15, weight: .bold), .foregroundColor: Theme.fg])
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 110)]
        para.headIndent = 110
        para.paragraphSpacing = 4
        for (k, v) in rows {
            out.append(NSAttributedString(string: "\(k)\t", attributes: [.font: Theme.ui(12), .foregroundColor: Theme.muted, .paragraphStyle: para]))
            out.append(NSAttributedString(string: "\(v)\n", attributes: [.font: Theme.ui(12.5), .foregroundColor: Theme.fg, .paragraphStyle: para]))
        }
        text.textStorage?.setAttributedString(out)
    }
}
