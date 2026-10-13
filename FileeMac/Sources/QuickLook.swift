import AppKit
import FileeCore
import Quartz

/// Space: the system Quick Look panel over the active pane's selection.
extension BrowserWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            guard !activePane.selectedItems.isEmpty else {
                NSSound.beep()
                return
            }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        activePane.selectedItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let items = activePane.selectedItems
        guard index < items.count else { return nil }
        return items[index].url as NSURL
    }

    /// Arrow keys and Space while the panel is up go to the file list, so the preview follows the cursor.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 49 {
            panel.orderOut(nil)
            return true
        }
        activePane.fileView.focusTarget.keyDown(with: event)
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL else { return .zero }
        return activePane.fileView.screenFrame(of: url.path) ?? .zero
    }
}
