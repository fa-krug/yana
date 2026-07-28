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
            // Built as an interpolated `Text` rather than a plain Swift `String` so the four nouns
            // reach the string catalog like every other label on this screen.
            row("Library", Text("\(diagnostics.feedCount) feeds · \(diagnostics.tagCount) tags · \(diagnostics.articleCount) articles · \(diagnostics.storedImageCount) images"))
            // Text, not the plain-String overload: the count is a countable noun ("N entries") and
            // must route through the string catalog like the `Library` row above — see
            // `SyncDiagnostics.systemLogText`.
            row("System Log", diagnostics.systemLogText)
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

    /// Verbatim value (identifiers, versions, timestamps — nothing translatable).
    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        row(label, Text(verbatim: value))
    }

    private func row(_ label: LocalizedStringKey, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value
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
