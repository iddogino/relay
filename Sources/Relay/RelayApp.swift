import SwiftUI
import RelayUI

@main
struct RelayApp: App {
    @State private var model: AppModel
    @StateObject private var updater = UpdaterModel()
    @AppStorage(UpdaterModel.earlyBuildsDefaultsKey) private var receiveEarlyBuilds = false

    init() {
        _model = State(initialValue: AppModel.makeForApp())
    }

    var body: some Scene {
        RelayScenes(model: model) {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
                Toggle("Receive Early Builds", isOn: $receiveEarlyBuilds)
            }
        }
    }
}
