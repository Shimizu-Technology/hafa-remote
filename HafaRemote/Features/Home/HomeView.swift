import SwiftUI

struct HomeView: View {
    @State private var isShowingSetup = false

    var body: some View {
        NavigationStack {
            ZStack {
                HafaTheme.canvas
                    .ignoresSafeArea()

                VStack(spacing: 28) {
                    Spacer()

                    Image(systemName: "tv")
                        .font(.system(size: 50, weight: .medium))
                        .foregroundStyle(HafaTheme.accent)
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text("No TV connected")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)

                        Text("Add a Samsung TV on this Wi-Fi network to get started.")
                            .font(.body)
                            .foregroundStyle(HafaTheme.secondaryText)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        isShowingSetup = true
                    } label: {
                        Label("Add Samsung TV", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HafaTheme.accent)
                    .foregroundStyle(HafaTheme.canvas)
                    .accessibilityIdentifier("addSamsungTVButton")

                    Spacer()
                }
                .padding(.horizontal, 24)
            }
            .navigationTitle("Hafa Remote")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $isShowingSetup) {
                SetupPlaceholderView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct SetupPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "TV setup is next",
                systemImage: "wifi",
                description: Text("The next build adds secure Samsung TV pairing on your local network.")
            )
            .navigationTitle("Add a TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    HomeView()
}
