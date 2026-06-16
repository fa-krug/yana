import SwiftData
import SwiftUI

/// Transient tag filter for the Articles list. Mirrors `TagFilterView`'s layout but writes to
/// the caller's local `@State` (via bindings) instead of `AppSettings`, so it never affects
/// the home timeline filter. All tags active by default.
struct ArticleTagFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @Binding var disabledTagNames: Set<String>
    @Binding var includeUntagged: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(tags) { tag in
                    Toggle(tag.name, isOn: Binding(
                        get: { !disabledTagNames.contains(tag.name) },
                        set: { active in
                            if active { disabledTagNames.remove(tag.name) }
                            else { disabledTagNames.insert(tag.name) }
                        }
                    ))
                }
                Toggle(String(localized: "Untagged"), isOn: $includeUntagged)
            }
            .navigationTitle("Filter")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
