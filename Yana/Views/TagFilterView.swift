import SwiftData
import SwiftUI

/// Filter sheet: every tag plus an "Untagged" entry, each a toggle. All active by default.
/// Writes the disabled set / untagged flag to `AppSettings`.
struct TagFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @State private var settings = AppSettings()
    /// Local mirror so toggles animate; synced to settings on change.
    @State private var disabled: Set<String> = []
    @State private var includeUntagged = true

    var body: some View {
        NavigationStack {
            List {
                ForEach(tags) { tag in
                    toggleRow(tag.name, isActive: !disabled.contains(tag.name)) { active in
                        if active { disabled.remove(tag.name) } else { disabled.insert(tag.name) }
                        settings.disabledTagNames = disabled
                    }
                }
                toggleRow(String(localized: "Untagged"), isActive: includeUntagged) { active in
                    includeUntagged = active
                    settings.includeUntagged = active
                }
            }
            .navigationTitle("Filter")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                disabled = settings.disabledTagNames
                includeUntagged = settings.includeUntagged
            }
        }
    }

    private func toggleRow(_ name: String, isActive: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(name, isOn: Binding(get: { isActive }, set: set))
    }
}
