import SwiftUI

/// Library prefs: update interval. Retention is server-side only (the device holds no
/// retention-days setting to configure).
struct LibrarySettingsSection: View {
    @State private var settings = AppSettings()

    var body: some View {
        Section {
            Picker(selection: $settings.updateInterval) {
                ForEach(UpdateInterval.allCases) { interval in
                    Text(interval.localizedLabel).tag(interval)
                }
            } label: {
                Label("Background Updates", systemImage: "arrow.clockwise")
                    .labelStyle(.tintedIcon(.blue))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        } header: {
            Text("Library")
        }
    }
}
