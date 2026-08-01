import SwiftUI

/// Library prefs: retention window, update interval.
struct LibrarySettingsSection: View {
    @State private var settings = AppSettings()

    var body: some View {
        Section {
            Stepper(value: $settings.retentionDays, in: 1...365) {
                Label("Keep Articles: \(settings.retentionDays) days", systemImage: "calendar")
                    .labelStyle(.tintedIcon(.blue))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
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
