import Foundation
import SwiftData
import Testing
@testable import Yana

/// How the summary block reaches the app's derived text surfaces, and what the summarize action
/// writes. The summary is body content now rather than a column beside it, so both directions
/// matter: it has to appear in the surfaces derived from the body, and it has to be kept back out
/// of the text fed to the summarizer.
@Suite("Summary block text surfaces")
@MainActor
struct SummaryBlockTests {

    private let lead: Block = .image(ref: "yana-img://lead", caption: [])

    /// One-paragraph summary contents, typed explicitly so assertions compare `[Block]` to
    /// `[Block]` rather than leaning on literal inference through an optional.
    private func onePara(_ text: String) -> [Block] { [.paragraph([InlineRun(text: text)])] }

    // MARK: - plainText (search + read-aloud)

    /// Searching for a phrase that only appears in a summary should find the article, and read-aloud
    /// should speak the summary where the reader shows it -- so `plainText` flattens it in place.
    @Test func plainTextIncludesTheSummaryInDocumentOrder() {
        let blocks: [Block] = [
            lead,
            .summary([.paragraph([InlineRun(text: "The short version.")])]),
            .paragraph([InlineRun(text: "The article itself.")]),
        ]
        #expect(BlockParser.plainText(blocks) == "The short version.\n\nThe article itself.")
    }

    @Test func plainTextFlattensEveryParagraphOfAMultiParagraphSummary() {
        let blocks: [Block] = [.summary([
            .paragraph([InlineRun(text: "First half.")]),
            .paragraph([InlineRun(text: "Second half.")]),
        ])]
        #expect(BlockParser.plainText(blocks) == "First half.\n\nSecond half.")
    }

    // MARK: - The summarize action

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Article.self, Feed.self, Tag.self,
                                          configurations: .init(isStoredInMemoryOnly: true))
        return container.mainContext
    }

    private func makeArticle(in context: ModelContext, blocks: [Block]) -> Article {
        let article = Article(title: "A Title", identifier: "art-1", url: "https://example.test/a")
        article.blocks = blocks
        context.insert(article)
        return article
    }

    @Test func summarizeWritesTheSummaryIntoTheSlotAfterTheLeadImage() async throws {
        let context = try makeContext()
        let article = makeArticle(in: context, blocks: [
            lead, .paragraph([InlineRun(text: "The article itself.")]),
        ])
        let provider = StubProvider(result: .success("The short version."))

        let result = await ReaderActions.summarize(article, using: provider, modelContext: context)

        #expect(result == .saved)
        let blocks = article.blocks
        #expect(blocks.count == 3)
        guard case .image = blocks[0] else { Issue.record("lead media must stay first"); return }
        guard case .summary(let inner) = blocks[1] else { Issue.record("summary must be second"); return }
        #expect(inner == onePara("The short version."))
    }

    /// The legacy column is read-only now: writing it as well would put the same summary in two
    /// places and reintroduce the "which one does the reader draw" question the block kind settles.
    @Test func summarizeDoesNotWriteTheLegacySummaryColumn() async throws {
        let context = try makeContext()
        let article = makeArticle(in: context, blocks: [.paragraph([InlineRun(text: "Body.")])])
        let provider = StubProvider(result: .success("The short version."))

        _ = await ReaderActions.summarize(article, using: provider, modelContext: context)

        #expect(article.summary.isEmpty)
        #expect(Block.containsSummary(article.blocks))
    }

    /// Re-summarizing replaces the existing summary rather than stacking a second one.
    @Test func reSummarizingReplacesTheExistingSummary() async throws {
        let context = try makeContext()
        let article = makeArticle(in: context, blocks: [
            lead,
            .summary([.paragraph([InlineRun(text: "Stale summary.")])]),
            .paragraph([InlineRun(text: "The article itself.")]),
        ])
        let provider = StubProvider(result: .success("Fresh summary."))

        _ = await ReaderActions.summarize(article, using: provider, modelContext: context)

        let blocks = article.blocks
        #expect(blocks.count == 3)
        #expect(Block.summaryContents(of: blocks) == onePara("Fresh summary."))
    }

    /// The model is fed the *article* -- not the article plus its own previous summary, which
    /// `Article.plainText` (the input before this change) now includes.
    @Test func reSummarizingDoesNotFeedThePreviousSummaryBackToTheModel() async throws {
        let context = try makeContext()
        let article = makeArticle(in: context, blocks: [
            lead,
            .summary([.paragraph([InlineRun(text: "Stale summary.")])]),
            .paragraph([InlineRun(text: "The article itself.")]),
        ])
        #expect(article.plainText.contains("Stale summary."))   // the trap this guards against

        _ = await ReaderActions.summarize(article, using: EchoProvider(), modelContext: context)

        // EchoProvider hands back whatever it was given, so the saved summary *is* the model input.
        #expect(Block.summaryContents(of: article.blocks) == onePara("The article itself."))
    }

    @Test func summarizeSplitsAMultiParagraphSummaryIntoOneBlock() async throws {
        let context = try makeContext()
        let article = makeArticle(in: context, blocks: [.paragraph([InlineRun(text: "Body.")])])
        let provider = StubProvider(result: .success("First half.\n\nSecond half.\n\n"))

        _ = await ReaderActions.summarize(article, using: provider, modelContext: context)

        // One summary block holding two paragraphs -- not two blocks, which would push the article
        // down the document.
        let expected: [Block] = [
            .paragraph([InlineRun(text: "First half.")]),
            .paragraph([InlineRun(text: "Second half.")]),
        ]
        #expect(Block.summaryContents(of: article.blocks) == expected)
    }

    @Test func aFailedSummarizeLeavesTheBlocksAlone() async throws {
        let context = try makeContext()
        let body: [Block] = [lead, .paragraph([InlineRun(text: "Body.")])]
        let article = makeArticle(in: context, blocks: body)
        let provider = StubProvider(result: .failure(.promptTooLong))

        let result = await ReaderActions.summarize(article, using: provider, modelContext: context)

        #expect(result == .failed(.promptTooLong))
        #expect(article.blocks == body)
    }

    // MARK: - Read-aloud

    /// `plainText` already carries a block summary, so prepending `Article.summary` on top of it
    /// would read the summary out twice.
    @Test func spokenTextDoesNotRepeatABlockSummary() throws {
        let context = try makeContext()
        let article = makeArticle(in: context, blocks: [
            .summary([.paragraph([InlineRun(text: "The short version.")])]),
            .paragraph([InlineRun(text: "The article itself.")]),
        ])
        article.summary = "The short version."   // as a pre-change build would have left it

        let spoken = ReaderSpeechController.spokenText(for: article)

        #expect(spoken.occurrences(of: "The short version.") == 1)
    }

    /// The other side of that guard: a summary produced by a pre-change build has no block, so it
    /// still has to be spoken.
    @Test func spokenTextStillReadsALegacyColumnSummary() throws {
        let context = try makeContext()
        let article = makeArticle(in: context, blocks: [.paragraph([InlineRun(text: "The article itself.")])])
        article.summary = "The short version."

        #expect(ReaderSpeechController.spokenText(for: article).contains("The short version."))
    }
}

/// Provider stubs live at file scope, not nested in the `@MainActor` suite: they conform to
/// `AISummaryProvider`, which is `Sendable` with a nonisolated requirement, so keeping them clear of
/// the suite's actor isolation avoids any question of a nested type inheriting it.
private struct StubProvider: AISummaryProvider {
    let result: Result<String, AISummaryFailure>

    func summarize(content: String, title: String) async -> Result<String, AISummaryFailure> {
        result
    }
}

/// Returns its input as the summary, so what the model was handed shows up in the saved block --
/// no shared mutable state needed to inspect it.
private struct EchoProvider: AISummaryProvider {
    func summarize(content: String, title: String) async -> Result<String, AISummaryFailure> {
        .success(content)
    }
}

private extension String {
    /// How many times `needle` occurs in this string.
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
