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
        .commands { MiningSettingsCommands() }
        Window("Settings", id: "settings") { SettingsView(model: model).frame(minWidth: 560, minHeight: 480).padding(16) }
            .defaultSize(width: 660, height: 800)
            .windowResizability(.contentMinSize)
            .defaultLaunchBehavior(.suppressed)
    }
}

private struct MiningSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
