import SwiftUI

/// Library prefs: retention window, background refresh interval.
struct LibrarySettingsSection: View {
    @State private var settings = AppSettings()

    var body: some View {
        Section("Library") {
            Stepper(value: $settings.retentionDays, in: 1...365) {
                Label("Keep Articles: \(settings.retentionDays) days", systemImage: "calendar")
                    .labelStyle(.tintedIcon(.blue))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Stepper(value: $settings.backgroundInterval, in: 300...21600, step: 300) {
                Label("Background Refresh: \(Int(settings.backgroundInterval / 60)) min",
                      systemImage: "arrow.clockwise")
                    .labelStyle(.tintedIcon(.blue))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}
