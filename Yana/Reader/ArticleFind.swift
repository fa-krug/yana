import Foundation

/// The pure half of "Find in Article": which stretches of an article body are searchable text,
/// where a query matches inside them, which match is current, and how the reader should paint
/// the result. Nothing here touches a view. `ReaderBlockViewController` owns one
/// `ArticleFindState` per page and feeds the resulting `FindHighlights` into `ArticleBlockView`,
/// and the two find bars (the iOS pager's, the Mac detail pane's) only ever talk to that controller.
///
/// Everything is keyed by **the renderer's own segmentation** (`BodySegment.segments(from:)`), not
/// by block position in `Article.blocks`: a match has to be painted into, and scrolled to inside,
/// exactly the view that draws it, and that view is chosen per segment. A top-level run of prose is
/// one `SelectableText` holding several blocks, a list item's paragraph is a SwiftUI `Text` nested
/// inside a list segment, and so on. `FindUnitID` names one searchable text unit inside one segment
/// in the terms both sides agree on.

/// One searchable text unit inside a rendered body: `segment` is the `BodySegment.id` that draws
/// it, `path` locates it within that segment the same way the renderer recurses. For a coalesced
/// text run the path is `[blockIndex]`; for a standalone block it is `[]` for the block itself
/// (a code block, an image's caption), `[item, block, …]` under a list, `[block, …]` under a
/// blockquote or summary card -- mirroring `BlockNodeView`'s recursion exactly, so a unit id built
/// here and one built by the renderer for the same text are equal.
struct FindUnitID: Hashable, Sendable {
    let segment: Int
    let path: [Int]

    init(segment: Int, path: [Int] = []) {
        self.segment = segment
        self.path = path
    }

    func appending(_ indices: Int...) -> FindUnitID {
        FindUnitID(segment: segment, path: path + indices)
    }

    /// The lead image's caption: the header draws the first block when it is an image, and that
    /// block is always body segment 0 with nothing above it.
    static let leadImage = FindUnitID(segment: 0)
}

/// A searchable text unit: its id, the exact visible text the renderer draws for it, and how the
/// reader can scroll to it. `isTextViewBacked` units are hosted in a `UITextView` that is the only
/// one in its segment (`ReaderTextView.findSegment`), so a match can be located to the line; other
/// units are SwiftUI `Text` and can only be scrolled to at segment granularity.
/// `textViewOffset` is where this unit's text starts inside that text view's string -- non-zero
/// only for the blocks a coalesced text run merges into one string (`ReaderAttributedText.make(blocks:)`).
struct FindUnit: Equatable, Sendable {
    let id: FindUnitID
    let ordinal: Int
    let text: String
    let isTextViewBacked: Bool
    let textViewOffset: Int
}

/// One occurrence of the query. `range` is in UTF-16 units of the unit's own text (what both
/// `NSAttributedString` and `AttributedString`'s `NSRange` conversion index by).
struct FindMatch: Equatable, Sendable {
    let unit: FindUnitID
    /// Document order of the unit, so two matches from different lists can be compared.
    let unitOrdinal: Int
    let range: NSRange
    let isTextViewBacked: Bool
    let textViewOffset: Int

    /// The match's range inside the hosting text view's string (see `FindUnit.textViewOffset`).
    var textViewRange: NSRange {
        NSRange(location: textViewOffset + range.location, length: range.length)
    }

    /// Document position, for "the first match at or after where the user was".
    fileprivate var position: (Int, Int) { (unitOrdinal, range.location) }
}

/// The searchable text of one article body, derived once per page from the renderer's segments.
struct ArticleFindIndex: Equatable, Sendable {
    let units: [FindUnit]

    init(segments: [BodySegment]) {
        var units: [FindUnit] = []
        for segment in segments {
            switch segment.kind {
            case .textRun(let blocks):
                var offset = 0
                for (i, block) in blocks.enumerated() {
                    let text: String
                    switch block {
                    case .paragraph(let runs), .heading(_, let runs):
                        text = Self.text(of: runs)
                    default:
                        continue   // a text run only ever holds paragraphs/headings
                    }
                    Self.append(text, id: FindUnitID(segment: segment.id, path: [i]),
                                textViewBacked: true, offset: offset, into: &units)
                    // Mirrors `ReaderAttributedText.make(blocks:)`: each block's text, then one
                    // newline between blocks.
                    offset += text.utf16.count + 1
                }
            case .summary(let inner):
                for (j, block) in inner.enumerated() {
                    Self.collect(block, id: FindUnitID(segment: segment.id, path: [j]),
                                 textViewBacked: false, into: &units)
                }
            case .single(let block):
                Self.collect(block, id: FindUnitID(segment: segment.id), textViewBacked: true, into: &units)
            }
        }
        self.units = units
    }

    /// Every occurrence of `query`, in document order, non-overlapping within a unit.
    /// Case- and diacritic-insensitive ("uber" finds "Über"); a blank query matches nothing.
    func matches(for query: String) -> [FindMatch] {
        guard !Self.isBlank(query) else { return [] }
        var result: [FindMatch] = []
        for unit in units {
            var from = unit.text.startIndex
            while from < unit.text.endIndex,
                  let found = unit.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                              range: from..<unit.text.endIndex) {
                result.append(FindMatch(unit: unit.id, unitOrdinal: unit.ordinal,
                                        range: NSRange(found, in: unit.text),
                                        isTextViewBacked: unit.isTextViewBacked,
                                        textViewOffset: unit.textViewOffset))
                // A diacritic-insensitive hit is never empty, but never spin on the off chance.
                from = found.isEmpty ? unit.text.index(after: found.lowerBound) : found.upperBound
            }
        }
        return result
    }

    static func isBlank(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Unit collection

    private static func text(of runs: [InlineRun]) -> String {
        runs.map(\.text).joined()
    }

    /// Recurses a standalone block the way `BlockNodeView` does. `textViewBacked` is true only for
    /// the root of a `.single` segment: a code block or an image caption there is the segment's one
    /// `SelectableText`; anything nested (list items, blockquote contents) renders as SwiftUI `Text`,
    /// and a nested caption/code block shares its segment with other text views, so neither can be
    /// located by segment.
    private static func collect(_ block: Block, id: FindUnitID, textViewBacked: Bool, into units: inout [FindUnit]) {
        switch block {
        case .paragraph(let runs), .heading(_, let runs):
            // A top-level paragraph is coalesced into a text run and never reaches here as a
            // `.single`; one can only arrive nested, as SwiftUI `Text`.
            append(text(of: runs), id: id, textViewBacked: false, offset: 0, into: &units)
        case .codeBlock(let text, _):
            append(text, id: id, textViewBacked: textViewBacked && id.path.isEmpty, offset: 0, into: &units)
        case .image(_, let caption):
            append(text(of: Block.captionRuns(caption)), id: id,
                   textViewBacked: textViewBacked && id.path.isEmpty, offset: 0, into: &units)
        case .list(_, let items):
            for (i, item) in items.enumerated() {
                for (j, inner) in item.enumerated() {
                    collect(inner, id: id.appending(i, j), textViewBacked: false, into: &units)
                }
            }
        case .blockquote(let inner), .summary(let inner):
            for (j, child) in inner.enumerated() {
                collect(child, id: id.appending(j), textViewBacked: false, into: &units)
            }
        case .embed, .divider:
            break   // an embed's title is a button label, not body text
        }
    }

    private static func append(_ text: String, id: FindUnitID, textViewBacked: Bool, offset: Int,
                               into units: inout [FindUnit]) {
        guard !text.isEmpty else { return }
        units.append(FindUnit(id: id, ordinal: units.count, text: text,
                              isTextViewBacked: textViewBacked, textViewOffset: offset))
    }
}

/// What the find bar shows beside the field.
enum FindStatus: Equatable, Sendable {
    /// No query typed yet.
    case idle
    case noMatches
    /// `current` is 1-based.
    case match(current: Int, total: Int)
}

/// The live state of one page's find session: the query, its matches, and which one is current.
struct ArticleFindState: Equatable, Sendable {
    private(set) var query = ""
    private(set) var matches: [FindMatch] = []
    private(set) var currentIndex: Int?

    var current: FindMatch? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    var hasQuery: Bool { !ArticleFindIndex.isBlank(query) }

    var status: FindStatus {
        guard hasQuery else { return .idle }
        guard let currentIndex, !matches.isEmpty else { return .noMatches }
        return .match(current: currentIndex + 1, total: matches.count)
    }

    /// Re-run the search for `query`. The current match is kept whenever the new query still
    /// matches at the very same spot -- typing "ca", then "cat", refines the match under the reader
    /// rather than yanking them elsewhere -- and otherwise moves to the first match at or after
    /// where they were, so refining a query walks forward through the article instead of
    /// snapping back to the top. With nothing to anchor on, the first match wins.
    mutating func update(query: String, in index: ArticleFindIndex) {
        let previous = current
        self.query = query
        matches = index.matches(for: query)
        guard !matches.isEmpty else { currentIndex = nil; return }
        guard let previous else { currentIndex = 0; return }
        if let same = matches.firstIndex(where: { $0.unit == previous.unit && $0.range.location == previous.range.location }) {
            currentIndex = same
        } else if let ahead = matches.firstIndex(where: { $0.position >= previous.position }) {
            currentIndex = ahead
        } else {
            currentIndex = 0
        }
    }

    /// Advance to the next match, wrapping to the first after the last.
    mutating func next() {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? -1) + 1) % matches.count
    }

    /// Step back to the previous match, wrapping to the last before the first.
    mutating func previous() {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? 0) - 1 + matches.count) % matches.count
    }

    /// What the renderer paints for this state.
    var highlights: FindHighlights { FindHighlights(matches: matches, current: current) }
}

/// One highlighted range inside a unit's text.
struct FindHighlightRange: Equatable, Sendable {
    let range: NSRange
    let isCurrent: Bool
}

/// The per-unit highlight ranges the renderer paints. A value type handed into `ArticleBlockView`
/// on every find change; `.empty` is the resting state every page renders with.
struct FindHighlights: Equatable, Sendable {
    private let ranges: [FindUnitID: [NSRange]]
    let current: FindMatch?

    static let empty = FindHighlights(matches: [], current: nil)

    init(matches: [FindMatch], current: FindMatch?) {
        var ranges: [FindUnitID: [NSRange]] = [:]
        for match in matches { ranges[match.unit, default: []].append(match.range) }
        self.ranges = ranges
        self.current = current
    }

    var isEmpty: Bool { ranges.isEmpty }

    func ranges(for unit: FindUnitID) -> [FindHighlightRange] {
        guard let list = ranges[unit] else { return [] }
        return list.map { range in
            FindHighlightRange(range: range,
                               isCurrent: current?.unit == unit && current?.range == range)
        }
    }
}

/// A one-shot request for `ArticleBlockView` to scroll a body segment on screen, for a match whose
/// text view the `LazyVStack` has not built yet (or that has no text view at all, being SwiftUI
/// `Text` nested in a list). `token` always changes so a repeat request for the same segment is not
/// deduplicated by SwiftUI's value-equality change detection.
struct FindScrollRequest: Equatable, Sendable {
    let segment: Int
    let token: Int
}
