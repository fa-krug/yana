import SwiftUI

/// One diagnostics log entry: level glyph, category, timestamp, and the message in a monospaced
/// selectable font.
struct SyncLogRow: View {
    let entry: SyncLog.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: levelIcon)
                    .foregroundStyle(levelColor)
                    .font(.caption)
                Text(entry.category)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                if entry.source == .system {
                    Text(verbatim: "sys")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                // `CloudKitSyncMonitor` emits a whole error tree as ONE multi-line entry (see its
                // `record`), so an uncapped row can be hundreds of lines tall — which destroys `List`
                // performance and makes the trace unnavigable. 12 rather than the spec's 4: an error
                // tree legitimately needs domain, code, message and a couple of nested levels before
                // it says anything. The full text is still in the copied/shared export.
                .lineLimit(12)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var levelIcon: String {
        switch entry.level {
        case .error: "exclamationmark.triangle.fill"
        case .notice: "bell.fill"
        case .info: "info.circle.fill"
        case .debug: "ant.fill"
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .error: .red
        case .notice: .orange
        case .info: .blue
        case .debug: .gray
        }
    }
}
