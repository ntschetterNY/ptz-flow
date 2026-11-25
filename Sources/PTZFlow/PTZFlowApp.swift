import AppKit
import SwiftUI

@main
struct PTZFlowApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Lets the window come to the front when started with `swift run` as well as from the .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("PTZ Flow") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(.dark)
        }
    }
}
