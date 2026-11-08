#if os(iOS)
import QuickLook
import UIKit

/// Shows fetched remote files in Quick Look, presented over the app (iOS's
/// counterpart of the Mac's Quick Look panel, with its own Share sheet).
@MainActor
final class QuickLookPreviewer: NSObject {
    static let shared = QuickLookPreviewer()

    private var items: [URL] = []

    func preview(_ url: URL) {
        items = [url]
        let controller = QLPreviewController()
        controller.dataSource = self
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }
}

extension QuickLookPreviewer: QLPreviewControllerDataSource {
    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        MainActor.assumeIsolated { items[index] as NSURL }
    }
}
#endif
