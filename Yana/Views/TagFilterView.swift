import SwiftData
import SwiftUI

/// Filter sheet: a Tags section (every tag plus an "Untagged" entry) and a Feeds section,
/// each row a toggle. All active by default. Writes the disabled sets / untagged flag to
/// `AppSettings`. A "Clear All" action re-enables everything.
struct TagFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @Query(sort: \Feed.name) private var feeds: [Feed]
    @State private var settings = AppSettings()
    /// Local mirrors so toggles animate; synced to settings on change.
    @State private var disabledTags: Set<String> = []
    @State private var disabledFeeds: Set<String> = []
    @State private var includeUntagged = true

    private var isFiltering: Bool {
        !disabledTags.isEmpty || !disabledFeeds.isEmpty || !includeUntagged
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Tags") {
                    ForEach(tags) { tag in
                        Toggle(isOn: Binding(
                            get: { !disabledTags.contains(tag.name) },
                            set: { active in
                                if active { disabledTags.remove(tag.name) } else { disabledTags.insert(tag.name) }
                                settings.disabledTagNames = disabledTags
                            }
                        )) {
                            Label { Text(tag.name) } icon: { TagColorDot(colorHex: tag.colorHex) }
                        }
                    }
                    toggleRow(String(localized: "Untagged"), isActive: includeUntagged) { active in
                        includeUntagged = active
                        settings.includeUntagged = active
                    }
                }

                if !feeds.isEmpty {
                    Section("Feeds") {
                        ForEach(feeds) { feed in
                            Toggle(isOn: Binding(
                                get: { !disabledFeeds.contains(feed.name) },
                                set: { active in
                                    if active { disabledFeeds.remove(feed.name) } else { disabledFeeds.insert(feed.name) }
                                    settings.disabledFeedNames = disabledFeeds
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
            .onAppear {
                disabledTags = settings.disabledTagNames
                disabledFeeds = settings.disabledFeedNames
                includeUntagged = settings.includeUntagged
            }
        }
    }

    private func clearAll() {
        withAnimation(Motion.resolve(.default, reduceMotion: reduceMotion)) {
            disabledTags = []
            disabledFeeds = []
            includeUntagged = true
        }
        settings.disabledTagNames = []
        settings.disabledFeedNames = []
        settings.includeUntagged = true
    }

    private func toggleRow(_ name: String, isActive: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(name, isOn: Binding(get: { isActive }, set: set))
    }
}
