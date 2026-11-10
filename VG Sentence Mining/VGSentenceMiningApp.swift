import SwiftUI

@main struct VGSentenceMiningApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 880, minHeight: 650)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.discardTemporaryData() }
        }
        .defaultSize(width: 1120, height: 800)
        .windowStyle(.hiddenTitleBar)
        Settings { SettingsView(model: model) }
            .defaultSize(width: 680, height: 740)
            .windowResizability(.contentMinSize)
    }
}
