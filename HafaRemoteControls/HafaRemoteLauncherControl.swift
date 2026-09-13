import AppIntents
import SwiftUI
import WidgetKit

/// A fast, system-native entry point from Control Center, the Lock Screen, or Action Button.
struct HafaRemoteLauncherControl: ControlWidget {
    static let kind = "com.shimizutechnology.hafaremote.controls.open-remote"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenHafaRemoteIntent()) {
                Label("Hafa Remote", systemImage: "tv")
            }
        }
        .displayName("Hafa Remote")
        .description("Open the remote for your last-used TV.")
    }
}
