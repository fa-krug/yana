import SwiftUI

/// Editable list of CSS selectors for the full-website extraction editor — one page for the
/// content list, one for the ignore list. An "Auto-generate with AI" toolbar action regenerates
/// and overwrites *this* list from a sample article page; it is hidden entirely when no AI
/// provider is usable.
struct SelectorListView: View {
    let kind: SelectorKind
    let navigationTitle: LocalizedStringKey
    @Binding var selectors: [String]
    /// The feed's identifier (homepage or feed URL) and current options, so the AI suggester can
    /// fetch a real sample article to analyze.
    let identifier: String
    let options: AggregatorOptions

    @State private var settings = AppSettings()
    @State private var isGenerating = false
    @State private var showConfirm = false
    @State private var errorMessage: String?

    private var aiReady: Bool { AIReadiness.isReady(provider: settings.activeAIProvider) }

    private var footerText: LocalizedStringKey {
        switch kind {
        case .content:
            return "Elements matching any of these selectors are combined to form the article body."
        case .ignore:
            return "Elements matching any of these selectors are removed from the article body."
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(selectors.indices, id: \.self) { index in
                    TextField("Selector", text: $selectors[index])
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                }
                .onDelete { selectors.remove(atOffsets: $0) }

                Button {
                    selectors.append("")
                } label: {
                    Label("Add Selector", systemImage: "plus")
                }
            } footer: {
                Text(footerText)
            }
        }
        .navigationTitle(navigationTitle)
        .toolbar {
            if aiReady {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showConfirm = true
                    } label: {
                        Label("Auto-generate with AI", systemImage: "sparkles")
                    }
                    .disabled(isGenerating || identifier.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .overlay {
            if isGenerating {
                ProgressView("Generating…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("Replace this list with AI suggestions?", isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Auto-generate", role: .destructive) { generate() }
        } message: {
            Text("The current selectors on this page will be overwritten.")
        }
        .alert("Couldn’t Generate Selectors", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func generate() {
        isGenerating = true
        let current = selectors
        Task {
            defer { isGenerating = false }
            do {
                let result = try await SelectorSuggester.suggest(
                    kind: kind, identifier: identifier, options: options,
                    current: current, settings: settings)
                if result.isEmpty {
                    errorMessage = String(localized: "The AI didn’t return any selectors. Try again.")
                } else {
                    selectors = result
                }
            } catch let error as SelectorSuggester.SuggestError {
                // Report which stage failed so a feed-loading problem isn't mistaken for an AI one.
                switch error {
                case .noProvider:
                    errorMessage = String(localized: "No AI provider is set up. Configure one in Settings, then try again.")
                case .noSampleArticle, .sampleFetchFailed:
                    errorMessage = String(localized: "Couldn’t load a sample article from this feed. Check the URL and your connection, then try again.")
                }
            } catch {
                errorMessage = String(localized: "The AI request failed. Check your connection and AI settings, then try again.")
            }
        }
    }
}
