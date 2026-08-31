import AppKit
@preconcurrency import Quartz

/// Hosts the shared Quick Look panel for fetched remote files. QL renders
/// every common type natively (images, PDFs, CSVs, text, video) and offers
/// its own "Open with …" hand-off, which is the whole preview story.
@MainActor
final class QuickLookPreviewer: NSObject {
    static let shared = QuickLookPreviewer()

    private var items: [NSURL] = []

    func preview(_ url: URL) {
        items = [url as NSURL]
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
}

extension QuickLookPreviewer: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    // Quick Look calls these on the main thread; the panel is only ever fed
    // from the main actor above.
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { items.indices.contains(index) ? items[index] : nil }
    }
}
