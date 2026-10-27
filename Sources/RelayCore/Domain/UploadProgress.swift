import Foundation

/// A snapshot of an in-flight upload, as reported by `uploadFiles`.
public struct UploadProgress: Sendable, Equatable {
    /// Bytes sent so far across every file of the drop.
    public var bytesTransferred: Int64
    /// Exact completion of the file currently in flight, 0...1.
    public var currentFileFraction: Double
    /// How many files have started so far (1-based once any started).
    public var filesStarted: Int

    public init(bytesTransferred: Int64, currentFileFraction: Double, filesStarted: Int) {
        self.bytesTransferred = bytesTransferred
        self.currentFileFraction = currentFileFraction
        self.filesStarted = filesStarted
    }
}
