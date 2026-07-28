import SwiftData
import SwiftUI

/// Filter sheet: a Tags section (every tag plus an "Untagged" entry) and a Feeds section,
/// each row a toggle. All active by default. Writes the disabled sets / untagged flag to
/// `AppSettings`. A "Clear All" action re-enables everything.
struct TagFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                // The `@Query`s live on `TagFilterListContent`, re-identified by `.id()` on a
                // CloudKit remote-change bump (see `LibraryRevision`) so they re-fetch — `@Query`
                // never sees `.NSPersistentStoreRemoteChange` on its own. The local mirrors
                // (disabledTags/disabledFeeds/includeUntagged) stay on this parent so a bump while
                // the sheet is open loses none of the user's in-progress toggles — the same trap
                // `.searchable()` hit on `ManagedList` (see its doc comment).
                TagFilterListContent(
                    disabledTags: $disabledTags,
                    disabledFeeds: $disabledFeeds,
                    includeUntagged: $includeUntagged,
                    settings: settings
                )
                .id(LibraryRevision.shared.token)
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
}

/// The `@Query`-owning half of `TagFilterView`, split out so a CloudKit remote-change `.id()` reset
/// only recreates this content (and its `@Query`s), not the parent's local toggle mirrors.
private struct TagFilterListContent: View {
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @Query(sort: \Feed.name) private var feeds: [Feed]
    @Binding var disabledTags: Set<String>
    @Binding var disabledFeeds: Set<String>
    @Binding var includeUntagged: Bool
    let settings: AppSettings

    var body: some View {
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
            toggleRow(String(localized: "Untagged"), isOn: Binding(
                get: { includeUntagged },
                set: { active in
                    includeUntagged = active
                    settings.includeUntagged = active
                }))
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

    private func toggleRow(_ name: String, isOn: Binding<Bool>) -> some View {
        Toggle(name, isOn: isOn)
    }
}
