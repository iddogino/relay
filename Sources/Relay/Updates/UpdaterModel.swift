import AppKit
import Combine
import RelayCore
import Sparkle

/// Owns the Sparkle updater for the app's lifetime and applies the release
/// channel policy. Uses Sparkle's standard UI (the familiar "A new version
/// is available" flow), including its one-time consent prompt for automatic
/// background checks.
@MainActor
final class UpdaterModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    nonisolated static let earlyBuildsDefaultsKey = "receiveEarlyBuilds"

    private(set) var controller: SPUStandardUpdaterController!
    @Published private(set) var canCheckForUpdates = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let optIn = UserDefaults.standard.bool(forKey: Self.earlyBuildsDefaultsKey)
        return UpdateChannels.allowed(currentVersion: version, earlyBuildsOptIn: optIn)
    }
}
