import SwiftUI

/// The pinned diagnostics summary above the log. Answers the two questions that explain most sync
/// failures — is there an iCloud account, and which CloudKit environment is this build talking to —
/// before any log line is read.
struct SyncLogHeaderView: View {
    let diagnostics: SyncDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("iCloud Account", diagnostics.accountStatus)
            row("Container", diagnostics.containerIdentifier)
            row("Environment", diagnostics.environment)
            row("App", diagnostics.appVersion)
            row("System", "\(diagnostics.systemVersion) · \(diagnostics.idiom)")
            row("Library", "\(diagnostics.feedCount) feeds · \(diagnostics.tagCount) tags · \(diagnostics.articleCount) articles · \(diagnostics.storedImageCount) images")
            row("Last Import", stamp(diagnostics.lastImportSucceededAt))
            row("Last Export", stamp(diagnostics.lastExportSucceededAt))
            if let error = diagnostics.lastErrorSummary {
                // Labeled "(this launch)" deliberately: CloudKitSyncMonitor never clears this on a
                // later success, because "sync failed at some point" stays worth knowing even after
                // a subsequent export succeeds. Without the qualifier a stale error reads as current.
                Text("Last Error (this launch)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func stamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
