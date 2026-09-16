#if os(macOS)
import AppKit

/// The AppKit twin of `ReaderFindBar` (`ReaderFindBar.swift`, `#if os(iOS)`). Same type name and
/// the same contract — `onQueryChange`/`onNext`/`onPrevious`/`onDone`, `query`, `isFieldFocused`,
/// `setStatus(_:)`, `focusField()`, `clearQuery()` — because `MacReaderContainerViewController`
/// programs against exactly that surface and must not fork.
///
/// It owns no search state: every change is reported through the callbacks, and the host forwards
/// them to the displayed `ReaderBlockViewController` and pushes the resulting `FindStatus` back with
/// `setStatus`. The Mac docks it at the top of the detail pane, Safari-style, so `separatorEdge` is
/// `.bottom` there; the parameter is kept for symmetry with the iOS bar, which docks at the bottom.
///
/// Three mappings are worth naming, because the AppKit shapes are not the obvious ones:
///
/// - **Live typing.** UIKit reports every keystroke through `.editingChanged`. `NSSearchField`'s own
///   action is *debounced* by default (`sendsWholeSearchString`), which would make the highlights
///   lag behind the query — so both debounce flags are turned off *and* `controlTextDidChange(_:)`
///   is taken as the primary signal, since that is the hook guaranteed to fire per keystroke.
///   Whichever arrives first wins: `report(_:)` drops a repeat of the query it last published, so
///   the two routes cannot double-fire and step the match forward twice on one keypress.
/// - **Return.** `textFieldShouldReturn` has no AppKit equivalent; Return arrives as the
///   `insertNewline:` command through `control(_:textView:doCommandBy:)`, which is intercepted so
///   the key steps to the next match rather than ending editing (Safari's behavior).
/// - **Focus.** There is no `becomeFirstResponder()` a view can call on itself — first responder is
///   the *window's* property, so focusing means asking the window, and the selection afterwards has
///   to go through the field editor rather than the field.
@MainActor
final class ReaderFindBar: NSView, NSSearchFieldDelegate {
    enum SeparatorEdge { case top, bottom }

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onDone: (() -> Void)?

    /// The text currently in the field.
    var query: String { field.stringValue }

    /// Whether the field has keyboard focus. A focused `NSTextField` is not itself the first
    /// responder: the window installs its *field editor* (an `NSTextView`) and makes that the
    /// responder, so the test is whether the current responder is a text view this field owns.
    var isFieldFocused: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === field { return true }
        guard let textView = responder as? NSTextView else { return false }
        return textView.delegate === field || field.currentEditor() === textView
    }

    private let field = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let previousButton: NSButton
    private let nextButton: NSButton
    private let doneButton: NSButton

    /// The query most recently handed to `onQueryChange`, so the field's two change routes (see the
    /// type comment) cannot report the same edit twice.
    private var lastReportedQuery: String?

    init(separatorEdge: SeparatorEdge) {
        previousButton = NSButton()
        nextButton = NSButton()
        doneButton = NSButton()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("reader.findBar")

        // A material rather than a flat fill, so the bar reads as chrome over the scrolling body.
        // `.headerView` is AppKit's material for exactly this role — a bar pinned above content
        // inside a window — and `.withinWindow` blends it against the article rather than the
        // desktop behind the window.
        let background = NSVisualEffectView()
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        field.placeholderString = String(localized: "Find in article")
        field.setAccessibilityIdentifier("reader.find.field")
        field.delegate = self
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(queryChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.setAccessibilityIdentifier("reader.find.status")
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configure(previousButton, systemImage: "chevron.up",
                  label: String(localized: "Previous match"), identifier: "reader.find.previous",
                  action: #selector(previousTapped))
        configure(nextButton, systemImage: "chevron.down",
                  label: String(localized: "Next match"), identifier: "reader.find.next",
                  action: #selector(nextTapped))

        doneButton.title = String(localized: "Done")
        doneButton.bezelStyle = .accessoryBarAction
        doneButton.setButtonType(.momentaryPushIn)
        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        doneButton.setAccessibilityIdentifier("reader.find.done")
        doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [field, statusLabel, previousButton, nextButton, doneButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separatorEdge == .top
                ? separator.topAnchor.constraint(equalTo: topAnchor)
                : separator.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setStatus(.idle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: NSButton, systemImage: String, label: String, identifier: String,
                           action: Selector) {
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.title = ""
        button.bezelStyle = .accessoryBar
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    // MARK: - API

    /// Reflect the displayed page's find state: the count beside the field, and whether the
    /// chevrons have anything to step through.
    func setStatus(_ status: FindStatus) {
        switch status {
        case .idle:
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
        case .noMatches:
            statusLabel.stringValue = String(localized: "No matches")
            statusLabel.isHidden = false
        case .match(let current, let total):
            statusLabel.stringValue = String(localized: "\(current) of \(total)")
            statusLabel.isHidden = false
        }
        let hasMatches: Bool
        if case .match = status { hasMatches = true } else { hasMatches = false }
        previousButton.isEnabled = hasMatches
        nextButton.isEnabled = hasMatches
    }

    /// Put the cursor in the field with any previous query selected, so typing replaces it while
    /// Return/Next still step through the old one.
    func focusField() {
        window?.makeFirstResponder(field)
        if !field.stringValue.isEmpty { field.currentEditor()?.selectAll(nil) }
    }

    func clearQuery() {
        field.stringValue = ""
        lastReportedQuery = ""
    }

    // MARK: - Events

    /// Publishes a query change exactly once, whichever of the two routes (the search action or
    /// `controlTextDidChange`) noticed it first.
    private func report(_ value: String) {
        guard lastReportedQuery != value else { return }
        lastReportedQuery = value
        onQueryChange?(value)
    }

    @objc private func queryChanged() { report(query) }
    @objc private func previousTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func doneTapped() { onDone?() }

    func controlTextDidChange(_ notification: Notification) { report(query) }

    /// Return steps to the next match and keeps the field focused, like Safari's find. Returning
    /// `true` says the command was handled, which is what stops AppKit also ending editing.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        onNext?()
        return true
    }
}
#endif
