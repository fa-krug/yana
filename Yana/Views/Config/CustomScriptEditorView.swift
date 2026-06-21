import SwiftUI

/// AI-driven editor for a custom-script feed: a brief + a Try button. Tapping **Generate & Try**
/// asks the configured AI provider to write the script, runs it (stopping at the first emitted
/// article), and previews that article rendered through the real aggregation pipeline. The
/// generated JavaScript is editable by hand under a disclosure for the rare tweak.
struct CustomScriptEditorView: View {
    @Binding var options: CustomScriptOptions
    let seedURL: String

    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings()
    @State private var brief: String
    @State private var isWorking = false
    @State private var preview: AggregatedArticle?
    @State private var logs: [String] = []
    @State private var errorText: String?

    init(options: Binding<CustomScriptOptions>, seedURL: String) {
        _options = options
        self.seedURL = seedURL
        _brief = State(initialValue: options.wrappedValue.prompt)
    }

    private var canGenerate: Bool {
        !isWorking
            && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !seedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Describe this feed") {
                    TextField("e.g. Collect the latest posts from this site, with full article text; skip the newsletter box",
                              text: $brief, axis: .vertical)
                        .lineLimit(3...8)
                    if seedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Enter the feed's URL first.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(action: { Task { await generate() } }) {
                        HStack {
                            if isWorking { ProgressView() }
                            Text(isWorking ? "Working…" : "Generate & Try")
                        }
                    }
                    .disabled(!canGenerate)
                }

                if let errorText {
                    Section("Problem") {
                        Text(errorText).foregroundStyle(.red)
                    }
                }

                if let preview {
                    previewSection(preview)
                }

                if !logs.isEmpty {
                    Section("Log") {
                        ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced))
                        }
                    }
                }

                if !options.source.isEmpty {
                    Section {
                        DisclosureGroup("Script Source") {
                            TextEditor(text: $options.source)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(minHeight: 200)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                }
            }
            .navigationTitle("Custom Feed Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { options.prompt = brief; dismiss() }
                }
            }
        }
    }

    private func previewSection(_ article: AggregatedArticle) -> some View {
        Section("Preview") {
            Text(article.title).font(.headline)
            if !article.author.isEmpty {
                Text(article.author).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(excerpt(article.content))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Images and full formatting appear in the reader.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    @MainActor
    private func generate() async {
        errorText = nil
        preview = nil
        logs = []
        isWorking = true
        defer { isWorking = false }

        options.prompt = brief
        guard let textGenerator = ScriptGenerator.makeTextGenerator(settings: settings) else {
            errorText = String(localized: "AI is not configured. Add a provider in Settings.")
            return
        }

        do {
            let generator = ScriptGenerator(textGenerator: textGenerator)
            let result = try await generator.generate(brief: brief, seedURL: seedURL)
            options.source = result.source
            logs = result.preview?.logs ?? []
            if let error = result.error, result.preview?.articles.isEmpty ?? true {
                errorText = error
                return
            }
            preview = await renderPreview()
            if preview == nil {
                errorText = String(localized: "The script ran but produced no preview article.")
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Render the first emitted article through the real aggregation pipeline (sanitize, images,
    /// embeds) so the preview matches what the reader will show.
    @MainActor
    private func renderPreview() async -> AggregatedArticle? {
        let config = FeedConfig(type: .customScript, identifier: seedURL, dailyLimit: 1,
                                options: .customScript(options), collectedToday: 0)
        let credentials = AggregatorCredentials.resolved(scriptSecret: KeychainService.loadScriptSecret(forFeed: seedURL))
        let aggregator = CustomScriptAggregator(config: config, credentials: credentials, maxArticles: 1)
        return try? await aggregator.aggregate().first
    }

    private func excerpt(_ html: String) -> String {
        let text = (try? HTMLUtils.parse(html).text()) ?? ""
        return text.isEmpty ? String(localized: "(no text content)") : String(text.prefix(400))
    }
}
