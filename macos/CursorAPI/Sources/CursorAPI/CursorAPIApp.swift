import CursorAPICore
import SwiftUI

@main
struct CursorAPIMacApp: App {
    @StateObject private var model = CursorAPIAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 560)
                .task {
                    model.startServer(allowKeychainPrompt: false)
                }
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView(model: model)
                .frame(width: 560)
        }
    }
}
