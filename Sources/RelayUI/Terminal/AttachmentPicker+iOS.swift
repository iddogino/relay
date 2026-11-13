#if os(iOS)
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// What the key bar's attach button picked, before it's on disk here: the
/// upload wants plain files, and a photo is only a promise of one.
@MainActor
enum PickedAttachments {
    /// From the file browser: copies the picker made in the app's inbox.
    case files([URL])
    /// From the photo library: loaded (downloaded from iCloud, converted)
    /// on demand.
    case photos([NSItemProvider])

    var count: Int {
        switch self {
        case .files(let urls): urls.count
        case .photos(let providers): providers.count
        }
    }

    /// The files to upload, in a folder of their own that the caller
    /// removes afterwards.
    struct Staged {
        let directory: URL
        let urls: [URL]

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Gathers the picked items into one folder under names that differ:
    /// they land in a single folder on the host too.
    func stage() async throws -> Staged {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("relay-attach-\(UUID().uuidString)", isDirectory: true)
        let staged = directory.appendingPathComponent("staged", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        do {
            var incoming: [URL] = []
            switch self {
            case .files(let urls):
                incoming = urls
            case .photos(let providers):
                for (index, provider) in providers.enumerated() {
                    try Task.checkCancellation()
                    let folder = directory.appendingPathComponent("incoming-\(index)", isDirectory: true)
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    incoming.append(try await Self.loadFile(from: provider, into: folder))
                }
            }
            var taken = Set<String>()
            var urls: [URL] = []
            for source in incoming {
                let name = Self.uniqueName(source.lastPathComponent, taken: &taken)
                let destination = staged.appendingPathComponent(name)
                try fm.moveItem(at: source, to: destination)
                urls.append(destination)
            }
            try Task.checkCancellation()
            return Staged(directory: directory, urls: urls)
        } catch {
            try? fm.removeItem(at: directory)
            if case .files(let urls) = self {
                for url in urls { try? fm.removeItem(at: url) }
            }
            throw error
        }
    }

    /// `name`, or `name-2`, `name-3`… (before the extension) when taken.
    /// Compared without case: the host's file system may.
    static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        var candidate = name
        var counter = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while !taken.insert(candidate.lowercased()).inserted {
            candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    /// Loads a photo or video as a file in `folder`. The system's file only
    /// lasts for the length of its callback, hence the copy.
    private static func loadFile(from provider: NSItemProvider, into folder: URL) async throws -> URL {
        let type = [UTType.image, .movie]
            .first { provider.hasItemConformingToTypeIdentifier($0.identifier) }?.identifier
            ?? provider.registeredTypeIdentifiers.first
        guard let type else { throw AttachmentError.unreadable(provider.suggestedName) }
        let suggestedName = provider.suggestedName
        let load = PendingLoad()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                load.begin(continuation)
                let progress = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    guard let url else {
                        load.finish(.failure(error ?? AttachmentError.unreadable(suggestedName)))
                        return
                    }
                    do {
                        let destination = folder.appendingPathComponent(url.lastPathComponent)
                        try FileManager.default.copyItem(at: url, to: destination)
                        load.finish(.success(destination))
                    } catch {
                        load.finish(.failure(error))
                    }
                }
                load.setProgress(progress)
            }
        } onCancel: {
            load.cancel()
        }
    }

    enum AttachmentError: LocalizedError {
        case unreadable(String?)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                "Couldn\u{2019}t load \(name.map { "\u{201C}\($0)\u{201D}" } ?? "an item") from the photo library."
            }
        }
    }
}

/// One photo's load: finishes once, with its file or by being cancelled
/// (which doesn't wait for the system to notice).
private final class PendingLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CheckedContinuation<URL, any Error>?
    private var progress: Progress?
    private var cancelled = false

    /// Cancelled already (the task was, before it got here): fails now.
    func begin(_ continuation: CheckedContinuation<URL, any Error>) {
        let cancelled = lock.withLock {
            if !self.cancelled { stored = continuation }
            return self.cancelled
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }

    func setProgress(_ progress: Progress) {
        let cancel = lock.withLock {
            self.progress = progress
            return cancelled
        }
        if cancel { progress.cancel() }
    }

    func finish(_ result: Result<URL, any Error>) {
        let continuation = lock.withLock {
            defer { stored = nil }
            return stored
        }
        continuation?.resume(with: result)
    }

    func cancel() {
        let progress = lock.withLock {
            cancelled = true
            return self.progress
        }
        progress?.cancel()
        finish(.failure(CancellationError()))
    }
}

/// Presents the photo library or the file browser and reports what was
/// picked (nothing, when dismissed without a choice).
@MainActor
final class AttachmentPicker: NSObject {
    enum Source {
        case photoLibrary, files
    }

    private var completion: ((PickedAttachments?) -> Void)?

    func present(_ source: Source, from presenter: UIViewController, completion: @escaping (PickedAttachments?) -> Void) {
        // One at a time: a picker still up answers its own caller first.
        self.completion?(nil)
        self.completion = completion
        switch source {
        case .photoLibrary:
            // Needs no permission: the picker runs outside the app, which
            // gets only what was picked.
            var configuration = PHPickerConfiguration()
            configuration.selectionLimit = 0
            // JPEG and H.264 rather than HEIC and HEVC: what the tools on
            // the other end can read.
            configuration.preferredAssetRepresentationMode = .compatible
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            presenter.present(picker, animated: true)
        case .files:
            // Copies: nothing to keep access to afterwards.
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            picker.allowsMultipleSelection = true
            picker.delegate = self
            presenter.present(picker, animated: true)
        }
    }

    private func finish(_ picked: PickedAttachments?) {
        let completion = self.completion
        self.completion = nil
        completion?(picked)
    }
}

extension AttachmentPicker: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let providers = results.map(\.itemProvider)
        picker.dismiss(animated: true) { [weak self] in
            self?.finish(providers.isEmpty ? nil : .photos(providers))
        }
    }
}

extension AttachmentPicker: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls.isEmpty ? nil : .files(urls))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }
}
#endif
