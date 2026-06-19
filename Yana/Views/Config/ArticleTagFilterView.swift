import SwiftData
import SwiftUI

/// Transient filter for the Articles list. Mirrors `TagFilterView`'s layout (a Tags section and
/// a Feeds section) but writes to the caller's local `@State` (via bindings) instead of
/// `AppSettings`, so it never affects the home timeline filter. All tags/feeds active by default.
struct ArticleTagFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @Query(sort: \Feed.name) private var feeds: [Feed]
    @Binding var disabledTagNames: Set<String>
    @Binding var includeUntagged: Bool
    @Binding var disabledFeedNames: Set<String>

    private var isFiltering: Bool {
        !disabledTagNames.isEmpty || !includeUntagged || !disabledFeedNames.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Tags") {
                    ForEach(tags) { tag in
                        Toggle(isOn: Binding(
                            get: { !disabledTagNames.contains(tag.name) },
                            set: { active in
                                if active { disabledTagNames.remove(tag.name) }
                                else { disabledTagNames.insert(tag.name) }
                            }
                        )) {
                            Label { Text(tag.name) } icon: { TagColorDot(colorHex: tag.colorHex) }
                        }
                    }
                    Toggle(String(localized: "Untagged"), isOn: $includeUntagged)
                }

                if !feeds.isEmpty {
                    Section("Feeds") {
                        ForEach(feeds) { feed in
                            Toggle(isOn: Binding(
                                get: { !disabledFeedNames.contains(feed.name) },
                                set: { active in
                                    if active { disabledFeedNames.remove(feed.name) }
                                    else { disabledFeedNames.insert(feed.name) }
                                }
                            )) {
                                Text(feed.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear All", action: clearAll).disabled(!isFiltering)
                }
                ToolbarItem(placement: .confirmationAction) { ConfirmCircleButton { dismiss() } }
            }
        }
    }

    private func clearAll() {
        withAnimation {
            disabledTagNames = []
            disabledFeedNames = []
            includeUntagged = true
        }
    }
}
