import SwiftUI

/// AI-driven editor for a custom-script feed: a brief + a Try button. Tapping **Generate & Try**
/// asks the configured AI provider to write the script, runs it (stopping at the first emitted
/// article), and previews that article rendered through the real aggregation pipeline and reader
/// renderer (images included). The generated JavaScript is editable by hand under a disclosure for
/// the rare tweak. An optional per-feed secret is stored in the Keychain and exposed to the script
/// as `input.secret`.
struct CustomScriptEditorView: View {
    @Binding var options: CustomScriptOptions
    let seedURL: String

    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings()
    @State private var brief: String
    @State private var secret: String
    @State private var isWorking = false
    @State private var previewHTML: String?
    @State private var logs: [String] = []
    @State private var errorText: String?

    init(options: Binding<CustomScriptOptions>, seedURL: String) {
        _options = options
        self.seedURL = seedURL
        _brief = State(initialValue: options.wrappedValue.prompt)
        _secret = State(initialValue: KeychainService.loadScriptSecret(forFeed: seedURL) ?? "")
    }

    private var trimmedSeedURL: String { seedURL.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canGenerate: Bool {
        !isWorking
            && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !trimmedSeedURL.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Describe this feed") {
                    TextField("e.g. Collect the latest posts from this site, with full article text; skip the newsletter box",
                              text: $brief, axis: .vertical)
                        .lineLimit(3...8)
                    if trimmedSeedURL.isEmpty {
                        Text("Enter the feed's URL first.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !trimmedSeedURL.isEmpty {
                    Section("API Secret (optional)") {
                        SecureField("Secret or API key", text: $secret)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("Stored in the Keychain and passed to the script as input.secret. Never included when a script is shared.")
                            .font(.caption)
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

                if let previewHTML {
                    Section("Preview") {
                        ScriptPreviewWebView(html: previewHTML)
                            .frame(height: 360)
                            .listRowInsets(EdgeInsets())
                        Text("This is how the article will appear in the reader.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
                    Button("Done") { commit(); dismiss() }
                }
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func generate() async {
        errorText = nil
        previewHTML = nil
        logs = []
        isWorking = true
        defer { isWorking = false }

        commit()   // persist brief + secret so the run sees them
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
            if let article = await renderPreview() {
                previewHTML = renderedHTML(for: article)
            } else {
                errorText = String(localized: "The script ran but produced no preview article.")
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Persist the brief onto the options and the secret into the Keychain (keyed by seed URL).
    private func commit() {
        options.prompt = brief
        guard !trimmedSeedURL.isEmpty else { return }
        if secret.isEmpty {
            KeychainService.deleteScriptSecret(forFeed: seedURL)
        } else {
            KeychainService.saveScriptSecret(secret, forFeed: seedURL)
        }
    }

    /// Run the first emitted article through the real aggregation pipeline (sanitize, images,
    /// embeds) so the preview matches the reader.
    @MainActor
    private func renderPreview() async -> AggregatedArticle? {
        let config = FeedConfig(type: .customScript, identifier: seedURL, dailyLimit: 1,
                                options: .customScript(options), collectedToday: 0)
        let credentials = AggregatorCredentials.resolved(scriptSecret: KeychainService.loadScriptSecret(forFeed: seedURL))
        let aggregator = CustomScriptAggregator(config: config, credentials: credentials, maxArticles: 1)
        return try? await aggregator.aggregate().first
    }

    /// Build a transient `Article` and render it with the reader's `ArticleRenderer` + current theme.
    @MainActor
    private func renderedHTML(for article: AggregatedArticle) -> String {
        let model = Article(title: article.title, identifier: "preview", url: article.url,
                            rawContent: article.rawContent, content: article.content, date: article.date,
                            author: article.author, iconURL: article.iconURL, summary: article.summary)
        model.createdAt = article.date
        return ArticleRenderer.fullPageHTML(article: model,
                                            theme: ArticleThemesManager.shared.currentTheme,
                                            textSize: settings.articleTextSize)
    }
}
