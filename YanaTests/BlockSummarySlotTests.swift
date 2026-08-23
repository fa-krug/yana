import Testing
@testable import Yana

/// The document's summary slot: lead media first (when there is one), summary second, article after
/// them. These helpers are the only code that decides where that is -- the renderer
/// (`ArticleBlockView`), the summarize action (`ReaderActions`) and the sync writer
/// (`SyncWriter.applyContent`) all go through them, so a drift here is a drift everywhere.
@Suite("Block summary slot")
struct BlockSummarySlotTests {

    private let lead: Block = .image(ref: "yana-img://lead", caption: [])
    private let body: Block = .paragraph([InlineRun(text: "The article itself.")])
    private func summary(_ text: String) -> [Block] { [.paragraph([InlineRun(text: text)])] }

    private func summaryCount(in blocks: [Block]) -> Int {
        blocks.reduce(into: 0) { count, block in
            if case .summary = block { count += 1 }
        }
    }

    // MARK: - Finding one

    @Test func containsSummaryOnlyMatchesTheTopLevel() {
        #expect(Block.containsSummary([lead, .summary(summary("s")), body]))
        #expect(!Block.containsSummary([lead, body]))
        // A summary buried in a list item is not the *article's* summary. The renderer still draws
        // it, but it must not satisfy "this document already has a summary" -- otherwise a real one
        // would never be inserted.
        #expect(!Block.containsSummary([.list(ordered: false, items: [[.summary(summary("s"))]])]))
    }

    @Test func summaryContentsReturnsTheWrappedBlocks() {
        let inner = summary("Short version.")
        #expect(Block.summaryContents(of: [lead, .summary(inner), body]) == inner)
        #expect(Block.summaryContents(of: [lead, body]) == nil)
    }

    // MARK: - Inserting one

    @Test func insertsAfterALeadImage() {
        let result = Block.settingSummary(summary("s"), in: [lead, body])
        #expect(result.count == 3)
        guard case .image = result[0] else { Issue.record("lead media must stay first"); return }
        guard case .summary = result[1] else { Issue.record("summary must be second"); return }
        #expect(result[2] == body)
    }

    /// The lead media has no kind of its own -- an `embed` leading the document is lead media just
    /// as an `image` is, so the summary goes after it too.
    @Test func insertsAfterALeadEmbed() {
        let embed: Block = .embed(Embed(provider: .youtube, thumbnailRef: nil,
                                        externalURL: "https://example.test/v", title: nil))
        let result = Block.settingSummary(summary("s"), in: [embed, body])
        guard case .embed = result[0] else { Issue.record("lead media must stay first"); return }
        guard case .summary = result[1] else { Issue.record("summary must be second"); return }
    }

    @Test func insertsFirstWhenThereIsNoLeadMedia() {
        let result = Block.settingSummary(summary("s"), in: [body])
        guard case .summary = result[0] else { Issue.record("summary must be first"); return }
        #expect(result[1] == body)
    }

    @Test func insertsIntoAnEmptyDocument() {
        let result = Block.settingSummary(summary("s"), in: [])
        #expect(result.count == 1)
        guard case .summary = result[0] else { Issue.record("expected summary"); return }
    }

    /// Only the leading media counts. An image further down is body content, so a document that
    /// opens with prose still takes the summary at index 0.
    @Test func doesNotTreatALaterImageAsLeadMedia() {
        let result = Block.settingSummary(summary("s"), in: [body, lead])
        guard case .summary = result[0] else { Issue.record("summary must be first"); return }
    }

    // MARK: - Replacing one

    @Test func replacesAnExistingSummaryInPlaceWithoutMovingIt() {
        let before = [lead, Block.summary(summary("old")), body]
        let after = Block.settingSummary(summary("new"), in: before)
        #expect(after.count == before.count)
        #expect(Block.summaryContents(of: after) == summary("new"))
        guard case .image = after[0] else { Issue.record("lead media must stay first"); return }
        guard case .summary = after[1] else { Issue.record("summary must stay second"); return }
    }

    /// Re-summarizing must not stack summaries, however oddly the existing one is placed.
    @Test func replacesAMisplacedSummaryRatherThanAddingASecond() {
        let after = Block.settingSummary(summary("new"), in: [lead, body, .summary(summary("old"))])
        #expect(summaryCount(in: after) == 1)
        #expect(Block.summaryContents(of: after) == summary("new"))
    }

    // MARK: - Stripping them

    @Test func removingSummariesLeavesTheArticleUntouched() {
        let stripped = Block.removingSummaries(from: [lead, .summary(summary("s")), body])
        #expect(stripped == [lead, body])
        #expect(Block.removingSummaries(from: [lead, body]) == [lead, body])
    }

    // MARK: - Surviving a content re-fetch

    /// A summary generated on this device is body content now, so a content re-fetch would destroy
    /// it unless it is carried over. `SyncWriter.applyContent` depends on this.
    @Test func preservesALocalSummaryWhenTheServerSendsNone() {
        let previous = [lead, Block.summary(summary("local")), body]
        let incoming = [lead, Block.paragraph([InlineRun(text: "Refetched body.")])]
        let merged = Block.preservingSummary(from: previous, in: incoming)
        #expect(Block.summaryContents(of: merged) == summary("local"))
        guard case .summary = merged[1] else { Issue.record("carried summary must land in the slot"); return }
    }

    @Test func aServerSummaryWinsOverTheLocalOne() {
        let previous = [Block.summary(summary("local")), body]
        let incoming = [Block.summary(summary("from server")), body]
        #expect(Block.summaryContents(of: Block.preservingSummary(from: previous, in: incoming))
                == summary("from server"))
    }

    @Test func preserveIsANoOpWhenThereIsNothingToCarry() {
        let incoming = [lead, body]
        #expect(Block.preservingSummary(from: [lead, body], in: incoming) == incoming)
        #expect(Block.preservingSummary(from: [], in: incoming) == incoming)
    }
}
