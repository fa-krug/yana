import SwiftData
import SwiftUI

/// Create or edit a `Feed`. New feeds are inserted on save; existing feeds are updated.
struct FeedEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.sortOrder) private var allTags: [Tag]

    /// nil = create a new feed.
    let feed: Feed?
    @State private var model: FeedEditorModel
    @State private var showingSearch = false

    init(feed: Feed?) {
        self.feed = feed
        _model = State(initialValue: FeedEditorModel(feed: feed))
    }

    var body: some View {
        Form {
            Section("Feed") {
                TextField("Name", text: $model.name)
                Picker("Type", selection: Binding(get: { model.type }, set: { model.changeType($0) })) {
                    ForEach(AggregatorType.allCases) { type in
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

            AggregatorOptionsForm(options: $model.options)
        }
        .navigationTitle(model.isEditingExisting ? "Edit Feed" : "New Feed")
        .sheet(isPresented: $showingSearch) {
            IdentifierSearchView(kind: model.type.identifierKind) { picked in
                model.identifier = picked
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ConfirmCircleButton(isDisabled: !model.isValid) { save() }
            }
        }
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

    private func save() {
        let target = feed ?? Feed(name: "", aggregatorType: .feedContent, identifier: "")
        model.apply(to: target, availableTags: allTags)
        if feed == nil { modelContext.insert(target) }
        try? modelContext.save()
        dismiss()
    }
}
