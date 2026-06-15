import SwiftUI

/// Renders the per-type options for the active `AggregatorOptions` case, plus the shared
/// AI block. Editing goes through case-specific bindings back into the bound enum.
struct AggregatorOptionsForm: View {
    @Binding var options: AggregatorOptions

    var body: some View {
        Group {
            switch options {
            case .fullWebsite(let o):
                websiteSection(o)
            case .feedContent:
                EmptyView() // AI only
            case .reddit(let o):
                redditSection(o)
            case .youtube(let o):
                youtubeSection(o)
            case .podcast(let o):
                podcastSection(o)
            case .heise(let o):
                heiseSection(o)
            case .merkur(let o):
                toggleSection(isOn: o.removeEmptyElements, label: "Remove Empty Elements") {
                    var n = o; n.removeEmptyElements = $0; options = .merkur(n)
                }
            case .tagesschau(let o):
                tagesschauSection(o)
            case .explosm(let o):
                toggleSection(isOn: o.showAltText, label: "Show Alt Text") {
                    var n = o; n.showAltText = $0; options = .explosm(n)
                }
            case .darkLegacy(let o):
                toggleSection(isOn: o.showAltText, label: "Show Alt Text") {
                    var n = o; n.showAltText = $0; options = .darkLegacy(n)
                }
            case .caschysBlog(let o):
                toggleSection(isOn: o.skipAds, label: "Skip Advertisements") {
                    var n = o; n.skipAds = $0; options = .caschysBlog(n)
                }
            case .mactechnews(let o):
                mactechnewsSection(o)
            case .oglaf(let o):
                oglafSection(o)
            case .meinMmo(let o):
                toggleSection(isOn: o.combinePages, label: "Combine Multi-page Articles") {
                    var n = o; n.combinePages = $0; options = .meinMmo(n)
                }
            }

            aiSection
        }
    }

    // MARK: - Shared AI block

    private var aiSection: some View {
        Section("AI Post-Processing") {
            let ai = aiBinding
            Toggle("Summarize", isOn: ai.summarize)
            Toggle("Improve Writing", isOn: ai.improveWriting)
            Toggle("Translate", isOn: ai.translate)
            if ai.translate.wrappedValue {
                TextField("Translate to", text: ai.translateLanguage)
            }
        }
    }

    /// A binding to the active case's `AIOptions`, writing the whole case back on change.
    private var aiBinding: Binding<AIOptions> {
        Binding(
            get: { options.ai },
            set: { newAI in
                switch options {
                case .fullWebsite(var o): o.ai = newAI; options = .fullWebsite(o)
                case .feedContent(var o): o.ai = newAI; options = .feedContent(o)
                case .reddit(var o): o.ai = newAI; options = .reddit(o)
                case .youtube(var o): o.ai = newAI; options = .youtube(o)
                case .podcast(var o): o.ai = newAI; options = .podcast(o)
                case .heise(var o): o.ai = newAI; options = .heise(o)
                case .merkur(var o): o.ai = newAI; options = .merkur(o)
                case .tagesschau(var o): o.ai = newAI; options = .tagesschau(o)
                case .explosm(var o): o.ai = newAI; options = .explosm(o)
                case .darkLegacy(var o): o.ai = newAI; options = .darkLegacy(o)
                case .caschysBlog(var o): o.ai = newAI; options = .caschysBlog(o)
                case .mactechnews(var o): o.ai = newAI; options = .mactechnews(o)
                case .oglaf(var o): o.ai = newAI; options = .oglaf(o)
                case .meinMmo(var o): o.ai = newAI; options = .meinMmo(o)
                }
            }
        )
    }

    // MARK: - Per-type sections

    private func toggleSection(isOn: Bool, label: LocalizedStringKey, set: @escaping (Bool) -> Void) -> some View {
        Section("Options") {
            Toggle(label, isOn: Binding(get: { isOn }, set: set))
        }
    }

    private func websiteSection(_ o: WebsiteOptions) -> some View {
        Section("Options") {
            Toggle("Fetch Full Content", isOn: Binding(get: { o.useFullContent }, set: { var n = o; n.useFullContent = $0; options = .fullWebsite(n) }))
            TextField("Custom Content Selector", text: Binding(get: { o.customContentSelector }, set: { var n = o; n.customContentSelector = $0; options = .fullWebsite(n) }))
                .autocorrectionDisabled()
            TextField("Selectors to Remove", text: Binding(get: { o.customSelectorsToRemove }, set: { var n = o; n.customSelectorsToRemove = $0; options = .fullWebsite(n) }))
                .autocorrectionDisabled()
        }
    }

    private func redditSection(_ o: RedditOptions) -> some View {
        Section("Options") {
            Picker("Sort Order", selection: Binding(get: { o.subredditSort }, set: { var n = o; n.subredditSort = $0; options = .reddit(n) })) {
                Text("Hot").tag("hot")
                Text("New").tag("new")
                Text("Top").tag("top")
                Text("Rising").tag("rising")
            }
            Stepper("Minimum Comments: \(o.minComments)", value: Binding(get: { o.minComments }, set: { var n = o; n.minComments = $0; options = .reddit(n) }), in: 0...500)
            Stepper("Comment Limit: \(o.commentLimit)", value: Binding(get: { o.commentLimit }, set: { var n = o; n.commentLimit = $0; options = .reddit(n) }), in: 0...50)
            Stepper("Minimum Post Age: \(o.minAgeHours)h", value: Binding(get: { o.minAgeHours }, set: { var n = o; n.minAgeHours = $0; options = .reddit(n) }), in: 0...168)
            Toggle("Include Header Image", isOn: Binding(get: { o.includeHeaderImage }, set: { var n = o; n.includeHeaderImage = $0; options = .reddit(n) }))
        }
    }

    private func youtubeSection(_ o: YouTubeOptions) -> some View {
        Section("Options") {
            Stepper("Comment Limit: \(o.commentLimit)", value: Binding(get: { o.commentLimit }, set: { var n = o; n.commentLimit = $0; options = .youtube(n) }), in: 0...50)
        }
    }

    private func podcastSection(_ o: PodcastOptions) -> some View {
        Section("Options") {
            Toggle("Include Audio Player", isOn: Binding(get: { o.includePlayer }, set: { var n = o; n.includePlayer = $0; options = .podcast(n) }))
            Toggle("Include Download Link", isOn: Binding(get: { o.includeDownloadLink }, set: { var n = o; n.includeDownloadLink = $0; options = .podcast(n) }))
            Stepper("Artwork Max Width: \(o.artworkSize)", value: Binding(get: { o.artworkSize }, set: { var n = o; n.artworkSize = $0; options = .podcast(n) }), in: 100...1200, step: 50)
        }
    }

    private func heiseSection(_ o: HeiseOptions) -> some View {
        Section("Options") {
            Toggle("Include Forum Comments", isOn: Binding(get: { o.includeComments }, set: { var n = o; n.includeComments = $0; options = .heise(n) }))
            Stepper("Max Comments: \(o.maxComments)", value: Binding(get: { o.maxComments }, set: { var n = o; n.maxComments = $0; options = .heise(n) }), in: 0...50)
        }
    }

    private func mactechnewsSection(_ o: MactechnewsOptions) -> some View {
        Section("Options") {
            Toggle("Combine Multi-page Articles", isOn: Binding(get: { o.combinePages }, set: { var n = o; n.combinePages = $0; options = .mactechnews(n) }))
            Toggle("Include Comments", isOn: Binding(get: { o.includeComments }, set: { var n = o; n.includeComments = $0; options = .mactechnews(n) }))
            Stepper("Max Comments: \(o.maxComments)", value: Binding(get: { o.maxComments }, set: { var n = o; n.maxComments = $0; options = .mactechnews(n) }), in: 0...50)
        }
    }

    private func tagesschauSection(_ o: TagesschauOptions) -> some View {
        Section("Options") {
            Toggle("Skip Livestreams", isOn: Binding(get: { o.skipLivestreams }, set: { var n = o; n.skipLivestreams = $0; options = .tagesschau(n) }))
            Toggle("Skip Videos", isOn: Binding(get: { o.skipVideos }, set: { var n = o; n.skipVideos = $0; options = .tagesschau(n) }))
        }
    }

    private func oglafSection(_ o: OglafOptions) -> some View {
        Section("Options") {
            Toggle("Show Alt Text", isOn: Binding(get: { o.showAltText }, set: { var n = o; n.showAltText = $0; options = .oglaf(n) }))
            Toggle("Convert to Base64", isOn: Binding(get: { o.convertToBase64 }, set: { var n = o; n.convertToBase64 = $0; options = .oglaf(n) }))
        }
    }
}
