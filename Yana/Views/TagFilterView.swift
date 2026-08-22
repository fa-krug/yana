import SwiftData
import SwiftUI

/// Filter sheet: the quick filters (starred-only, read state), a Tags section (every tag plus an
/// "Untagged" entry) and a Feeds section, each row a toggle. Everything shown by default. Writes
/// the disabled sets / untagged flag / quick filters to `AppSettings`. A "Clear All" action
/// re-enables everything.
struct TagFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var settings
    /// Local mirrors so toggles animate; synced to settings on change.
    @State private var disabledTags: Set<String> = []
    @State private var disabledFeeds: Set<String> = []
    @State private var includeUntagged = true

    private var isFiltering: Bool {
        !disabledTags.isEmpty || !disabledFeeds.isEmpty || !includeUntagged
            || settings.starredOnly || settings.readFilter != .all
    }

    var body: some View {
        NavigationStack {
            List {
                // The `@Query`s live on `TagFilterListContent`; the local mirrors
                // (disabledTags/disabledFeeds/includeUntagged) stay on this parent instead.
                TagFilterListContent(
                    disabledTags: $disabledTags,
                    disabledFeeds: $disabledFeeds,
                    includeUntagged: $includeUntagged,
                    settings: settings
                )
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
        settings.starredOnly = false
        settings.readFilter = .all
    }
}

/// The `@Query`-owning half of `TagFilterView`, split out from the parent's local toggle mirrors.
private struct TagFilterListContent: View {
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \Feed.name) private var feeds: [Feed]
    @Binding var disabledTags: Set<String>
    @Binding var disabledFeeds: Set<String>
    @Binding var includeUntagged: Bool
    let settings: AppSettings

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.starredOnly },
                set: { settings.starredOnly = $0 }
            )) {
                Label { Text("Starred Only") } icon: { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            }
            // Read state is a three-way choice, not a toggle: "unread only" and "read only" are
            // both useful, and neither is the default.
            Picker(selection: Binding(
                get: { settings.readFilter },
                set: { settings.readFilter = $0 }
            )) {
                ForEach(ReadFilterMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                Label { Text("Read State") } icon: { Image(systemName: "circle.lefthalf.filled") }
            }
        }

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
