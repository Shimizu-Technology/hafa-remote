import SwiftUI

/// The iPhone application entry point for Hafa Remote.
@main
struct HafaRemoteApp: App {
    /// Builds the app's root scene.
    var body: some Scene {
        WindowGroup {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-remote") {
                    RemoteControlTestHarness()
                } else {
                    HomeView()
                }
            #else
                HomeView()
            #endif
        }
    }
}
