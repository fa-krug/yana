#if os(macOS)
import SwiftUI
import AppKit

/// The AppKit twin of `ReaderBlockViewController` (`ReaderBlockViewController.swift`,
/// `#if os(iOS)`). Same type name, same public surface — `article`, `reload()`, `summaryPending`,
/// `startsWithFastText`, the whole find state machine, and the reading-position save/restore pair —
/// so `MacReaderDetailView` and the tests program against one API.
///
/// **What is deliberately absent**: the full-screen tap zones. They exist on iOS to bring the
/// hidden nav/toolbars back, and the Mac detail view already constructs every page with
/// `allowsFullscreen: false` and an empty `onRequestShowBars`, so there is nothing for them to
/// restore. `hideBarsTapZonesActive(_:)` survives as a no-op purely so the shared call sites do not
/// have to fork.
///
/// Everything about the *reading position* below is a mechanism change only. The four behaviours it
/// encodes were measured on device, not reasoned out, and each one is called out at the site that
/// preserves it:
/// 1. a save with nothing to measure answers `nil` rather than `.zero` (`readingOffset`);
/// 2. a restore is held until the body can hold it, re-clamped every pass (`applyPendingReadingOffset`);
/// 3. the signal it waits on is the body's own growth, not another layout pass (`observeBodyScroll`);
/// 4. the re-apply hops to the next runloop turn (`bodyContentDidGrow`).
@MainActor
final class ReaderBlockViewController: NSViewController {

    let article: Article
    private let onRefresh: (() -> Void)?
    private let onRequestShowBars: () -> Void
    private let settings = AppSettings()

    private var host: NSHostingController<ArticleBlockView>!

    var summaryPending = false {
        didSet {
            guard summaryPending != oldValue else { return }
            // The placeholder summary shifts the segment ids every find unit is keyed by.
            invalidateFindIndex()
            rebuild()
        }
    }

    /// Set by the host on the page it is about to *display* so that page's first paint renders the
    /// body as plain text and upgrades to the selectable `NSTextView` a runloop later (keeping the
    /// TextKit layout off the first-paint path). Consumed once by the first `makeRootView`;
    /// prewarmed neighbors leave it false so they render straight to `SelectableText`.
    var startsWithFastText = false

    /// A reading position handed to `restoreReadingOffset`, held until it has actually been
    /// applied. A freshly built page has no laid-out content yet, so the restore has to wait.
    private var pendingReadingOffset: CGPoint?

    /// The body scroll view this controller currently has observers on, and the document view whose
    /// frame changes signal that the body grew. See `observeBodyScroll`.
    private var observedScrollView: NSScrollView?
    private var observedDocumentView: NSView?

    /// Retries attaching the growth observation while a restore is pending; see `armObservationRetry`.
    private var observationRetryTask: Task<Void, Never>?

    /// True between `willStartLiveScroll` and `didEndLiveScroll`.
    ///
    /// **This stands in for UIKit's `isDragging` / `isDecelerating`, and it is a weaker signal.**
    /// Those are live queries on the scroll view; AppKit publishes only the two edge notifications,
    /// so this can report scrolling that began *after* the observer was attached and nothing
    /// before. That is why `observeBodyScroll` attaches as soon as the scroll view exists, rather
    /// than only while a restore is pending: the guard has to be armed before the user can touch
    /// the wheel, or a slow restore drags the reader back under them.
    private var isUserScrolling = false

    init(article: Article, allowsFullscreen: Bool, onRefresh: (() -> Void)?, onRequestShowBars: @escaping () -> Void) {
        self.article = article
        self.onRefresh = onRefresh
        self.onRequestShowBars = onRequestShowBars
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `NSViewController` has no implicit view; without this it would look for a nib of its own
    /// name and trap. (`UIViewController` synthesizes a plain view instead.)
    ///
    /// The view is a small subclass rather than a plain `NSView` purely to get an appearance-change
    /// hook: `viewDidChangeEffectiveAppearance()` is an `NSView` method with **no**
    /// `NSViewController` counterpart, and the page background is a baked `CGColor` that has to be
    /// re-resolved when the user switches to dark mode (see `applyBackgroundColor`).
    override func loadView() {
        let pageView = ReaderPageBackgroundView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        pageView.onAppearanceChange = { [weak self] in self?.applyBackgroundColor() }
        view = pageView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundColor()

        host = NSHostingController(rootView: makeRootView())
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // AppKit has no `willMove(toParent:)` / `didMove(toParent:)` — `addChild(_:)` is the whole
        // containment handshake.

        // Re-render live (no app restart) when the article text size or font changes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: AppSettings.articleTextSizeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: AppSettings.articleFontDidChange, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Background

    /// `NSViewController` has no `view.backgroundColor`, so the reader's page background is a layer
    /// fill. `NSColor.cgColor` resolves the dynamic color against whatever appearance happens to be
    /// current at the moment of conversion, and a `CGColor` does not re-resolve later — hence the
    /// explicit drawing-appearance push, and hence `viewDidChangeEffectiveAppearance` below. Without
    /// the second half the page keeps a light background after the user switches to dark mode.
    private func applyBackgroundColor() {
        view.wantsLayer = true
        // Deliberately clear: the page inherits the window's own surface, which is what makes it
        // read as one piece with the toolbar above it (`MacRootView` hides the toolbar's own
        // background). Painting a colour here -- any colour, semantic or hand-picked -- put a
        // second shade next to the toolbar's and showed up as a seam. ../mysquad paints none
        // either. The appearance hook stays: a layer colour set later still has to be re-resolved.
        view.layer?.backgroundColor = nil
    }

    /// Re-render after the article's content changed underneath this page. The find index is
    /// rebuilt against the new body and the query re-run (without scrolling), so highlights and the
    /// bar's count never describe text that is no longer there.
    func reload() {
        invalidateFindIndex()
        rebuild()
    }

    // MARK: - Find in article

    /// The searchable text of this page, built once per body and dropped whenever the body (or the
    /// summary placeholder, which shifts segment ids) changes.
    private var findIndex: ArticleFindIndex?
    private(set) var findState = ArticleFindState()
    private var findScrollRequest: FindScrollRequest?
    /// The retry loop of a coarse-then-fine reveal (see `revealMatch`), cancelled by the next one.
    private var findRevealTask: Task<Void, Never>?

    /// What the find bar shows for this page.
    var findStatus: FindStatus { findState.status }

    /// Search this page for `query`, highlight every match, and scroll the current one on screen.
    /// Called on every keystroke: the state keeps the reader on the same match while the query is
    /// refined and otherwise moves forward from where they were (`ArticleFindState.update`).
    func setFindQuery(_ query: String) {
        findState.update(query: query, in: currentFindIndex())
        applyFind(reveal: true)
    }

    func findNext() {
        findState.next()
        applyFind(reveal: true)
    }

    func findPrevious() {
        findState.previous()
        applyFind(reveal: true)
    }

    /// Clear the highlights and forget the query. Cheap when nothing was being searched, so the
    /// host can call it on every cached page when a search ends or moves to another page.
    func endFind() {
        findRevealTask?.cancel()
        findRevealTask = nil
        guard findState != ArticleFindState() || findScrollRequest != nil else { return }
        findState = ArticleFindState()
        findScrollRequest = nil
        rebuild()
    }

    private func invalidateFindIndex() {
        findIndex = nil
        // Re-run a live query against the new body so `findState` never points into text that is
        // gone. No reveal: a content refresh must not scroll the reader.
        if findState.hasQuery {
            findState.update(query: findState.query, in: currentFindIndex())
        }
    }

    private func currentFindIndex() -> ArticleFindIndex {
        if let findIndex { return findIndex }
        let index = ArticleFindIndex(segments: BodySegment.segments(from: article.blocks,
                                                                     summaryPending: summaryPending))
        findIndex = index
        return index
    }

    private func applyFind(reveal: Bool) {
        rebuild()
        findRevealTask?.cancel()
        findRevealTask = nil
        guard reveal, let match = findState.current else { return }
        // A restore still waiting for the body to grow would drag the reader back off the match.
        releasePendingReadingOffset()
        revealMatch(match)
    }

    /// Scroll `match` on screen. Two routes, because the body is a `LazyVStack`:
    ///
    /// - **Fine**: the match is in a `ReaderTextView` tagged with its segment (a text run, a
    ///   top-level code block or caption) that the stack has already built. Its line rect is
    ///   measured with TextKit and the scroll view centers it -- or stays put when it is already
    ///   fully visible, so refining a query does not jitter the page.
    /// - **Coarse**: the text view does not exist yet (its segment is off screen and unbuilt), or
    ///   the match is SwiftUI `Text` nested in a list/blockquote with no text view of its own. The
    ///   segment is scrolled to via SwiftUI (`FindScrollRequest`), which makes the lazy stack build
    ///   it; for a text-view match the fine route is then retried over a few frames, since the
    ///   view lands a runloop or two later and the coarse jump only reached its segment's middle.
    private func revealMatch(_ match: FindMatch) {
        if match.isTextViewBacked, revealInTextView(match) { return }
        findScrollRequest = FindScrollRequest(segment: match.unit.segment,
                                              token: (findScrollRequest?.token ?? 0) + 1)
        rebuild()
        guard match.isTextViewBacked else { return }
        findRevealTask = Task { @MainActor [weak self] in
            for delay in [16, 50, 120, 250, 500] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, self.findState.current == match else { return }
                if self.revealInTextView(match) { return }
            }
        }
    }

    /// The fine route of `revealMatch`; false when the match's text view is not built yet.
    @discardableResult
    private func revealInTextView(_ match: FindMatch) -> Bool {
        guard let scroll = bodyScrollView,
              let document = scroll.documentView,
              let textView = findTextView(segment: match.unit.segment),
              textView.bounds.width > 0 else { return false }
        let range = match.textViewRange
        // `NSTextView.textStorage` and `.layoutManager` are both optional, unlike their UIKit
        // counterparts; a view mid-teardown legitimately has neither, and that is a "not built yet"
        // answer, not a failure.
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return false }
        guard range.location >= 0, NSMaxRange(range) <= (textView.textStorage?.length ?? 0) else { return false }
        layout.ensureLayout(forCharacterRange: range)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        // `textContainerInset` is an `NSSize` on AppKit (`.width`/`.height` applied symmetrically),
        // where UIKit uses a `UIEdgeInsets` with separate `.left`/`.top`. The reader sets it to
        // `.zero` anyway; this keeps the arithmetic honest if that ever changes.
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        // **The one real behavioral difference between the platforms in this method.** On UIKit,
        // converting a rect *to* a `UIScrollView` yields content coordinates, because a scroll
        // view's own bounds origin *is* its content offset. AppKit does not work that way: an
        // `NSScrollView`'s bounds origin never moves — its clip view's does — so converting to the
        // scroll view yields clip-view (viewport) coordinates, which slide out from under the
        // scroll the moment it happens. The document view is the one whose coordinate space is
        // fixed relative to the content, so that is what `scrollToReveal` is given.
        scrollToReveal(textView.convert(rect, to: document), in: scroll)
        return true
    }

    /// The one `ReaderTextView` drawing `segment`, if the lazy stack has built it.
    private func findTextView(segment: Int) -> ReaderTextView? {
        guard isViewLoaded, let root = host?.view else { return nil }
        var queue: [NSView] = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let textView = next as? ReaderTextView, textView.findSegment == segment { return textView }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }

    /// Bring `rect` (document coordinates) into view: left alone when it is already fully inside the
    /// visible region, otherwise centered there, clamped to the scrollable range.
    ///
    /// The "already visible" guard and the 8pt margin are what stop the page jittering while a find
    /// query is being refined, and they carry over from iOS unchanged. Only the coordinate model
    /// differs: the clip view's bounds are already *in* document coordinates and already exclude
    /// the content insets, so there is no `+ inset.top` translation of the kind the UIKit version
    /// does to get from `contentOffset` space into content space.
    private func scrollToReveal(_ rect: CGRect, in scroll: NSScrollView) {
        let visibleHeight = scroll.contentView.bounds.height
        guard visibleHeight > 0 else { return }
        let visibleTop = scroll.contentView.bounds.origin.y
        let margin: CGFloat = 8
        if rect.minY >= visibleTop + margin, rect.maxY <= visibleTop + visibleHeight - margin { return }
        let range = scrollableRange(of: scroll)
        let wanted = rect.midY - visibleHeight / 2
        let y = min(max(wanted, range.min), range.max)
        setBodyOffset(CGPoint(x: scroll.contentView.bounds.origin.x, y: y), in: scroll, animated: true)
    }

    // MARK: - Reading position

    /// The body's scroll view — SwiftUI's own backing scroll view for `ArticleBlockView`'s root
    /// `ScrollView`.
    ///
    /// **On iOS the equivalent lookup tests `isScrollEnabled`, and that test is load-bearing there,
    /// not a nicety:** `SelectableText`'s `UITextView` *is* a `UIScrollView` and sits deeper in the
    /// same tree with `isScrollEnabled == false` and `contentSize == bounds`. Its `contentOffset`
    /// accepts a write and reads back, but scrolls nothing and is discarded on the next text layout
    /// — so treating it as the reading position silently reports a value the reader never had.
    ///
    /// AppKit has no such property, and it does not need one, because `SelectableTextMacOS` builds a
    /// **bare** `NSTextView` (never `NSTextView.scrollableTextView()`), so there is exactly one
    /// `NSScrollView` in this tree. The predicate below is therefore defensive rather than
    /// load-bearing — it rejects any scroll view that is merely wrapping a text view — and it is
    /// written out in full so that the next person to read the two files side by side does not
    /// "fix" this one to match iOS and break it.
    private var bodyScrollView: NSScrollView? {
        guard isViewLoaded, let root = host?.view else { return nil }
        var queue: [NSView] = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scroll = next as? NSScrollView, let document = scroll.documentView,
               !(document is NSTextView) {
                return scroll
            }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }

    /// How far into this article the user has read, or `nil` when there is nothing to measure —
    /// the body isn't laid out, or its backing was purged while the app was in the background.
    ///
    /// The `nil` is the point: answering `.zero` here is indistinguishable from a user who really
    /// is at the top of the article, so a save taken while the views are being torn down
    /// overwrites a good stored position with 0, and the next launch has nothing to restore.
    ///
    /// The value is the clip view's bounds origin, which is AppKit's `contentOffset`. SwiftUI's
    /// document view is flipped, so y increases downward from the top of the article exactly as it
    /// does on iOS and the stored number means the same thing on both platforms.
    /// `ReaderSyncUpdateScrollTests` pins that rather than taking it on trust.
    var readingOffset: CGPoint? {
        guard let scroll = bodyScrollView, let document = scroll.documentView,
              document.frame.height > 0 else { return nil }
        return scroll.contentView.bounds.origin
    }

    /// Whether a restore is still waiting for the body to grow enough to hold it. Test-facing.
    var hasPendingReadingOffset: Bool { pendingReadingOffset != nil }

    /// Put a reading position onto this page — the position the reader was at when the app was
    /// last backgrounded or left (`AppSettings.timelineAnchorReadingOffset`), applied on a cold
    /// launch and on the return from a background trip.
    ///
    /// Applied immediately if the body is already laid out, otherwise retried until it lands (a
    /// page built from scratch has no content size yet).
    func restoreReadingOffset(_ offset: CGPoint) {
        pendingReadingOffset = offset
        observeBodyScroll()
        applyPendingReadingOffset()
        armObservationRetry()
    }

    /// Keep trying to attach `observeBodyScroll`'s growth observation over the next few frames,
    /// while a restore is still pending.
    ///
    /// **A restore can be asked for before the body's scroll view exists at all** — that is the cold
    /// launch case, where the page is built and handed its saved position before it is ever put in a
    /// window. `observeBodyScroll` can only attach once SwiftUI has built the scroll view, and there
    /// is no second chance to do so: `viewDidLayout` is not a reliable retry hook here for exactly
    /// the reason the growth observation exists in the first place — this controller's view is
    /// pinned to fixed constraints, so the body appearing and growing *inside* the hosting
    /// controller never lays this view out again. Without this the observation was simply never
    /// attached and the pending offset sat there forever (measured: the restore landed at 0).
    ///
    /// Bounded rather than open-ended, on the same frame schedule as the find reveal's retry: if the
    /// body has not appeared within half a second the page is not going to hold a restore anyway,
    /// and the pending value is harmless — `applyPendingReadingOffset` is still called from every
    /// `viewDidLayout` and from every growth notification once one does attach.
    private func armObservationRetry() {
        observationRetryTask?.cancel()
        observationRetryTask = Task { @MainActor [weak self] in
            for delay in [16, 50, 120, 250, 500] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, self.pendingReadingOffset != nil else { return }
                self.observeBodyScroll()
                self.applyPendingReadingOffset()
                if self.observedScrollView != nil { return }
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The body's scroll view may only exist now, so this is also where a restore requested
        // before the view loaded gets its observation attached.
        observeBodyScroll()
        applyPendingReadingOffset()
    }

    /// Attach the two observations the restore depends on, re-attaching if SwiftUI has since
    /// replaced the scroll view or its document view.
    ///
    /// **The growth observation is the riskiest single mapping in this file.** On iOS it is KVO on
    /// `UIScrollView.contentSize`; AppKit's `NSClipView`/`NSScrollView` publish no equivalent
    /// observable, so the signal is the *document view's own frame* changing — which is the same
    /// event, since SwiftUI sizes the document view to the body's content. `viewDidLayout` is not a
    /// substitute for it, for the same reason `viewDidLayoutSubviews` is not on iOS: this
    /// controller's view is pinned to fixed constraints, so the SwiftUI body growing *inside* the
    /// hosting controller never changes this view's bounds and never triggers another layout pass
    /// here. `postsFrameChangedNotifications` is opt-in, and without it the notification never
    /// arrives at all.
    private func observeBodyScroll() {
        guard let scroll = bodyScrollView, let document = scroll.documentView else { return }
        if observedScrollView === scroll && observedDocumentView === document { return }
        if let previous = observedScrollView {
            NotificationCenter.default.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification,
                                                     object: previous)
            NotificationCenter.default.removeObserver(self, name: NSScrollView.didEndLiveScrollNotification,
                                                     object: previous)
        }
        if let previous = observedDocumentView {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification,
                                                     object: previous)
        }
        observedScrollView = scroll
        observedDocumentView = document

        document.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(bodyContentDidGrow),
                                               name: NSView.frameDidChangeNotification, object: document)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollDidStart),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollDidEnd),
                                               name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }

    @objc private func bodyContentDidGrow() {
        // Hopped to the next runloop turn on purpose: the notification fires from inside SwiftUI's
        // own layout pass, and a scroll written there is overwritten again before it ever reaches
        // the screen. Applying after the pass settles is what makes the restore stick.
        DispatchQueue.main.async { [weak self] in self?.applyPendingReadingOffset() }
    }

    @objc private func liveScrollDidStart() { isUserScrolling = true }
    @objc private func liveScrollDidEnd() { isUserScrolling = false }

    /// Applies `pendingReadingOffset`, and keeps holding it until the body has actually grown
    /// enough to satisfy it.
    ///
    /// **Consuming it on the first layout pass is wrong**: a page is laid out well before it is
    /// finished growing — the first paint renders plain text and upgrades to `SelectableText` a
    /// runloop later (`startsWithFastText`), and a lead image resolves later still
    /// (`ArticleBlockView`'s reveal gate). Clamping to whatever short body existed at that instant
    /// and then throwing the target away leaves the reader short of where it was, with nothing left
    /// to correct it. So the clamp is applied every pass as a best effort, but the target is only
    /// released once the body can hold it exactly.
    ///
    /// The user always wins: once they start scrolling, the pending restore is abandoned rather
    /// than dragging them back (see `isUserScrolling` for how that guard differs from UIKit's).
    private func applyPendingReadingOffset() {
        guard let wanted = pendingReadingOffset, let scroll = bodyScrollView else { return }
        guard !isUserScrolling else { releasePendingReadingOffset(); return }
        let range = scrollableRange(of: scroll)
        // Nothing scrollable yet: the body hasn't laid out at all. Wait for the next pass.
        guard range.max > range.min else { return }
        let origin = scroll.contentView.bounds.origin
        let clamped = CGPoint(x: origin.x, y: min(max(wanted.y, range.min), range.max))
        if clamped.y >= wanted.y { releasePendingReadingOffset() }
        guard origin != clamped else { return }
        setBodyOffset(clamped, in: scroll, animated: false)
    }

    private func releasePendingReadingOffset() {
        pendingReadingOffset = nil
        observationRetryTask?.cancel()
        observationRetryTask = nil
    }

    /// The range the clip view's bounds origin may take, AppKit's equivalent of UIKit's
    /// `-inset.top … contentSize.height + inset.bottom - bounds.height`. `contentInsets` is
    /// AppKit's `adjustedContentInset`, and the clip view's height already excludes it — which is
    /// why the upper bound subtracts the *clip* height rather than the scroll view's own.
    private func scrollableRange(of scroll: NSScrollView) -> (min: CGFloat, max: CGFloat) {
        let inset = scroll.contentInsets
        let documentHeight = scroll.documentView?.frame.height ?? 0
        let minY = -inset.top
        let maxY = max(minY, documentHeight + inset.bottom - scroll.contentView.bounds.height)
        return (minY, maxY)
    }

    /// Scroll the body to `point` (clip-view bounds origin).
    ///
    /// **`reflectScrolledClipView` is mandatory, not tidying.** `NSClipView.scroll(to:)` and
    /// `setBoundsOrigin(_:)` move the clip view but do not tell the enclosing scroll view about it,
    /// so without the call the scrollers desync from the content and — more importantly here —
    /// SwiftUI's own scroll tracking never observes the change. UIKit's `setContentOffset` does
    /// both halves in one call.
    private func setBodyOffset(_ point: CGPoint, in scroll: NSScrollView, animated: Bool) {
        guard animated else {
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            scroll.contentView.animator().setBoundsOrigin(point)
        } completionHandler: {
            MainActor.assumeIsolated { scroll.reflectScrolledClipView(scroll.contentView) }
        }
    }

    @objc private func rebuild() { host?.rootView = makeRootView() }

    private func makeRootView() -> ArticleBlockView {
        // Consume-once: only the very first render (the page the host is about to show) defers the
        // selectable upgrade. Later rebuilds (font/size change, reload) go straight to selectable.
        let deferSelectable = startsWithFastText
        startsWithFastText = false
        return ArticleBlockView(
            article: ReaderArticle(article),
            textSize: settings.articleTextSize,
            font: settings.articleFont,
            summaryPending: summaryPending,
            deferSelectableText: deferSelectable,
            onOpenLink: { [weak self] url in self?.openExternally(url) },
            onPlayVideo: { [weak self] embed in self?.playVideo(embed) },
            onShowImage: { [weak self] ref in self?.showImage(ref) },
            onRefresh: onRefresh,
            find: findState.highlights,
            findScrollRequest: findScrollRequest
        )
    }

    /// Open an image in its own window.
    ///
    /// `presentAsModalWindow(_:)` rather than iOS's full-screen `present(_:animated:)`: the Mac
    /// convention for "look at this image" is a window with a close control, and AppKit resolves
    /// the presenting chain itself, so there is no `topmostPresenter` equivalent to go hunting for.
    private func showImage(_ ref: String) {
        presentAsModalWindow(ReaderImageViewerViewController(ref: ref))
    }

    /// Play a video embed in its own window. Falls back to opening the embed's URL externally when
    /// it isn't an inline-playable video (the card already routes those through `onOpenLink`, so
    /// this is just a safety net).
    private func playVideo(_ embed: Embed) {
        if let player = ReaderVideoPlayerViewController.make(for: embed) {
            presentAsModalWindow(player)
        } else if let url = URL(string: embed.externalURL) {
            openExternally(url)
        }
    }

    /// The Mac branch of `ReaderLinkPolicy.openExternally` collapses to `NSWorkspace.shared.open`,
    /// and ignores both `useSystemBrowser` (there is no in-app browser on macOS to choose against,
    /// which is why `ReaderSettingsSection` hides that toggle here) and the presenter. The call is
    /// routed through the policy anyway so the two platforms keep one link-opening entry point.
    private func openExternally(_ url: URL) {
        ReaderLinkPolicy.openExternally(url, useSystemBrowser: settings.useSystemBrowser) { [weak self] in
            self
        }
    }

    // MARK: - Full-screen tap zones

    /// No-op on macOS: there is no tap-to-hide full-screen mode, so there are no hidden bars for a
    /// tap zone to bring back. Kept so shared call sites do not have to fork.
    func hideBarsTapZonesActive(_ active: Bool) { _ = active }
}

/// The controller's own view. Exists only to forward `viewDidChangeEffectiveAppearance()`, which
/// AppKit declares on `NSView` and not on `NSViewController` — so a controller that paints its
/// background into a layer has no other way to learn that light/dark mode changed under it.
private final class ReaderPageBackgroundView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
#endif
