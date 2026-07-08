import SwiftData
import SwiftUI

/// Create or edit a `Feed`. New feeds are inserted on save; existing feeds are updated.
struct FeedEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.sortOrder) private var allTags: [Tag]

    /// nil = create a new feed.
    let feed: Feed?
    /// Invoked with the freshly inserted feed after a successful create (never on edit),
    /// so the presenter can immediately fetch its articles.
    let onCreate: ((Feed) -> Void)?
    @State private var model: FeedEditorModel
    @State private var showingSearch = false
    @State private var settings = AppSettings()

    init(feed: Feed?, onCreate: ((Feed) -> Void)? = nil) {
        self.feed = feed
        self.onCreate = onCreate
        _model = State(initialValue: FeedEditorModel(feed: feed))
    }

    /// Source-enabled types, always including the feed's current type so an existing
    /// feed of a now-inactive source still shows a valid selection while editing.
    private var availableTypes: [AggregatorType] {
        AggregatorType.allCases.filter { settings.isSourceEnabled($0) || $0 == model.type }
    }

    var body: some View {
        Form {
            Section("Feed") {
                TextField("Name", text: $model.name)
                    .submitLabel(.done)
                Picker("Type", selection: Binding(get: { model.type }, set: { model.changeType($0) })) {
                    ForEach(availableTypes) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                if !model.type.identifierChoices.isEmpty {
                    Picker("Feed", selection: $model.identifier) {
                        ForEach(feedChoices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                } else if model.type.identifierKind != .none {
                    HStack {
                        TextField(identifierLabel, text: $model.identifier)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if model.type.identifierKind == .subreddit || model.type.identifierKind == .youtubeChannel {
                            Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Stepper("Daily Limit: \(model.dailyLimit)", value: $model.dailyLimit, in: 1...200)
                Toggle("Enabled", isOn: $model.enabled)
            }

            Section("Tags") {
                if allTags.isEmpty {
                    Text("No tags yet. Create tags in the Tags screen.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(allTags) { tag in
                        Button {
                            toggleTag(tag.name)
                        } label: {
                            HStack {
                                TagColorDot(colorHex: tag.colorHex)
                                Text(tag.name)
                                Spacer()
                                if model.selectedTagNames.contains(tag.name) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }

            AggregatorOptionsForm(options: $model.options, identifier: model.identifier)
        }
        .navigationTitle(model.isEditingExisting ? "Edit Feed" : "New Feed")
        .sheet(isPresented: $showingSearch) {
            IdentifierSearchView(kind: model.type.identifierKind) { picked in
                model.identifier = picked
            }
        }
        // Create flow: explicit Cancel/confirm in a sheet. Edit flow: auto-save on dismiss.
        .modifier(EditorSaveBehavior(
            isCreating: feed == nil,
            canSave: model.isValid,
            onSave: { save(); dismiss() },
            onCancel: { dismiss() },
            onDisappearSave: save
        ))
    }

    /// Predefined choices for the current type, plus the current identifier as a
    /// "Current" row when it isn't one of them (so editing an off-list/custom feed
    /// doesn't render a blank Picker or silently drop the saved value).
    private var feedChoices: [(value: String, label: String)] {
        let choices = model.type.identifierChoices
        let trimmed = model.identifier.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !choices.contains(where: { $0.value == trimmed }) {
            return choices + [(trimmed, String(localized: "Current: \(trimmed)"))]
        }
        return choices
    }

    private var identifierLabel: String {
        switch model.type.identifierKind {
        case .url: String(localized: "Feed URL")
        case .subreddit: String(localized: "Subreddit (e.g. swift)")
        case .youtubeChannel: String(localized: "YouTube Channel ID or handle")
        case .none: ""
        }
    }

    private func toggleTag(_ name: String) {
        if model.selectedTagNames.contains(name) {
            model.selectedTagNames.remove(name)
        } else {
            model.selectedTagNames.insert(name)
        }
    }

    /// Auto-save on exit. Invalid entries are discarded: a new feed is never inserted,
    /// and an existing feed keeps its last valid state.
    private func save() {
        guard model.isValid else { return }
        let isNew = feed == nil
        // Resolve a homepage URL to its advertised feed for free-form URL feeds that are new or
        // whose identifier changed. `apply` has already filled in a missing scheme synchronously.
        let shouldResolve = model.type.resolvesFeedURL && (isNew || model.identifierChanged)
        let target = feed ?? Feed(name: "", aggregatorType: .fullWebsite, identifier: "")
        model.apply(to: target, availableTags: allTags)
        if isNew { modelContext.insert(target) }
        try? modelContext.save()

        guard shouldResolve else {
            // Auto-run a newly created feed so its articles appear without a manual "Update".
            if isNew { onCreate?(target) }
            return
        }
        // Discover the real feed URL, persist it, then (for new feeds) auto-run — so the first
        // fetch already uses the canonical feed URL. Resolution never throws; on failure the
        // normalized URL stays and the aggregator's own discovery still handles a homepage.
        let entered = target.identifier
        let context = modelContext
        Task { @MainActor in
            let resolved = await FeedURLResolver.resolvedFeedURL(entered)
            if resolved != entered {
                target.identifier = resolved
                try? context.save()
            }
            if isNew { onCreate?(target) }
        }
    }
}
