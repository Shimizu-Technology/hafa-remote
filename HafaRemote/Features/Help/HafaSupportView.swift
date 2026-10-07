import SwiftUI

/// Support is available before pairing. The demo destination owns only simulated state.
struct HafaSupportView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: RemoteSessionStore
    @State private var isShowingTVHelp = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        DemoRemoteView()
                    } label: {
                        Label("Try the Remote Offline", systemImage: "play.rectangle")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("openOfflineDemoButton")
                } footer: {
                    Text("Explore a simulated remote without discovering, pairing, or contacting a TV.")
                }

                Section("Troubleshooting") {
                    NavigationLink {
                        DiagnosticsView(recorder: session.diagnostics, metadata: session.diagnosticMetadata)
                    } label: {
                        Label("Diagnostics", systemImage: "doc.text.magnifyingglass")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("openDiagnosticsButton")
                    Button("TV Help & About", systemImage: "questionmark.circle") {
                        isShowingTVHelp = true
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("supportTVHelpButton")
                }
            }
            .scrollContentBackground(.hidden)
            .background(HafaTheme.canvas)
            .tint(HafaTheme.accent)
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isShowingTVHelp) { HafaRemoteHelpView() }
        }
    }
}
