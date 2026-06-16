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
                        ForEach(model.type.identifierChoices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                } else if model.type.identifierKind != .none {
                    TextField(identifierLabel, text: $model.identifier)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!model.isValid)
            }
        }
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
