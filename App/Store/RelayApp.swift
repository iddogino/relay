import SwiftUI
import RelayUI

/// The App Store app: RelayUI in the App Sandbox. The App Store updates
/// it, so unlike the direct download (App/Direct) it has no updater.
@main
struct RelayApp: App {
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel.makeForApp())
    }

    var body: some Scene {
        RelayScenes(model: model)
    }
}
