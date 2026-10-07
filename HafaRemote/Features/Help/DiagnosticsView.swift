import SwiftUI

/// Export is available only from an immutable report that the user has previewed.
struct DiagnosticsView: View {
    @Bindable var recorder: DiagnosticRecorder
    let metadata: DiagnosticMetadata
    @State private var preview: DiagnosticReport?

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Record diagnostics on this phone",
                    isOn: Binding(
                        get: { recorder.isEnabled },
                        set: { recorder.setEnabled($0) }
                    )
                )
                .accessibilityIdentifier("diagnosticsToggle")
            } footer: {
                Text(
                    "Off by default. Records up to 100 recent connection and delivery events in memory. Nothing is uploaded automatically. Turning this off clears the events."
                )
                .foregroundStyle(HafaTheme.secondaryText)
            }

            Section {
                Button("Preview Support Report", systemImage: "doc.text.magnifyingglass") {
                    preview = recorder.report(metadata: metadata)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("previewDiagnosticsButton")
                Button("Clear Events", systemImage: "trash", role: .destructive) {
                    recorder.clear()
                }
                .frame(minHeight: 44)
                .disabled(recorder.events.isEmpty)
            } footer: {
                Text(
                    "Reports include app and iOS versions, optional TV model and firmware, and coarse operation timing. Addresses, pairing credentials, device identities, TV names, Wi-Fi names, and entered text are excluded."
                )
                .foregroundStyle(HafaTheme.secondaryText)
            }
        }
        .scrollContentBackground(.hidden)
        .background(HafaTheme.canvas)
        .navigationTitle("Diagnostics")
        .tint(HafaTheme.accent)
        .sheet(
            isPresented: Binding(
                get: { preview != nil },
                set: { if !$0 { preview = nil } }
            )
        ) {
            if let preview { DiagnosticReportPreview(report: preview) }
        }
    }
}

private struct DiagnosticReportPreview: View {
    @Environment(\.dismiss) private var dismiss
    let report: DiagnosticReport

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Review before sharing")
                        .font(.headline)
                    Text(
                        "This exact report will be shared only if you choose a destination in the share sheet."
                    )
                    .foregroundStyle(HafaTheme.secondaryText)
                    Text(report.text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("diagnosticsReportPreview")
                    ShareLink(item: report.text) {
                        Label("Share This Report", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(HafaTheme.onAccent)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("shareDiagnosticsButton")
                }
                .padding(20)
            }
            .background(HafaTheme.canvas)
            .navigationTitle("Support Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .tint(HafaTheme.accent)
    }
}
