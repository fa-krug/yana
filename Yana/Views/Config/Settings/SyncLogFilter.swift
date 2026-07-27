import Foundation

/// The diagnostics log's filter, kept as a pure value so the matching rules are unit-tested without
/// standing up SwiftUI. `nil` level/source mean "all"; filters combine with AND.
struct SyncLogFilter: Equatable, Sendable {
    var text: String = ""
    var level: SyncLog.Level?
    var source: SyncLog.Source?

    func apply(to entries: [SyncLog.Entry]) -> [SyncLog.Entry] {
        entries.filter { entry in
            if let level, entry.level != level { return false }
            if let source, entry.source != source { return false }
            guard !text.isEmpty else { return true }
            return entry.message.localizedCaseInsensitiveContains(text)
                || entry.category.localizedCaseInsensitiveContains(text)
        }
    }
}
