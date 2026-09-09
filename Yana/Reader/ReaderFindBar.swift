import UIKit

/// The "Find in Article" bar both platforms show: a search field, the "n of m" count, previous/next
/// chevrons and Done. It owns no search state -- every change is reported through the callbacks,
/// and whoever hosts it (`ReaderArticleViewController` on iOS, `MacReaderContainerViewController`
/// on the Mac) forwards them to the displayed `ReaderBlockViewController` and pushes the resulting
/// `FindStatus` back with `setStatus`.
///
/// The iOS pager docks it at the bottom, riding on the keyboard layout guide so it sits on top of
/// the keyboard while typing and on the home indicator once the keyboard is dismissed; the Mac
/// detail pane docks it at the top, Safari-style. `separatorEdge` says which edge borders the
/// content so the hairline lands on that side.
@MainActor
final class ReaderFindBar: UIView, UITextFieldDelegate {
    enum SeparatorEdge { case top, bottom }

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onDone: (() -> Void)?

    /// The text currently in the field.
    var query: String { field.text ?? "" }
    /// Whether the field has keyboard focus.
    var isFieldFocused: Bool { field.isFirstResponder }

    private let field = UISearchTextField()
    private let statusLabel = UILabel()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    init(separatorEdge: SeparatorEdge) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "reader.findBar"

        // A material rather than a flat fill, so the bar reads as chrome over the scrolling body
        // (the same family as the nav bar and toolbar it sits beside).
        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        field.placeholder = String(localized: "Find in article")
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.accessibilityIdentifier = "reader.find.field"
        field.delegate = self
        field.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .right
        statusLabel.accessibilityIdentifier = "reader.find.status"
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configure(previousButton, systemImage: "chevron.up",
                  label: String(localized: "Previous match"), identifier: "reader.find.previous",
                  action: #selector(previousTapped))
        configure(nextButton, systemImage: "chevron.down",
                  label: String(localized: "Next match"), identifier: "reader.find.next",
                  action: #selector(nextTapped))

        var done = UIButton.Configuration.plain()
        done.title = String(localized: "Done")
        done.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        done.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.uiKit.font = UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
            return outgoing
        }
        doneButton.configuration = done
        doneButton.accessibilityIdentifier = "reader.find.done"
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [field, statusLabel, previousButton, nextButton, doneButton])
        stack.axis = .horizontal
        stack.alignment = .center
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
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            separatorEdge == .top
                ? separator.topAnchor.constraint(equalTo: topAnchor)
                : separator.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setStatus(.idle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: UIButton, systemImage: String, label: String, identifier: String,
                           action: Selector) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemImage)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        button.configuration = config
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    // MARK: - API

    /// Reflect the displayed page's find state: the count beside the field, and whether the
    /// chevrons have anything to step through.
    func setStatus(_ status: FindStatus) {
        switch status {
        case .idle:
            statusLabel.text = nil
            statusLabel.isHidden = true
        case .noMatches:
            statusLabel.text = String(localized: "No matches")
            statusLabel.isHidden = false
        case .match(let current, let total):
            statusLabel.text = String(localized: "\(current) of \(total)")
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
        field.becomeFirstResponder()
        if !(field.text ?? "").isEmpty { field.selectAll(nil) }
    }

    func clearQuery() { field.text = "" }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        field.resignFirstResponder()
    }

    // MARK: - Events

    @objc private func queryChanged() { onQueryChange?(query) }
    @objc private func previousTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func doneTapped() { onDone?() }

    /// Return steps to the next match and keeps the keyboard up, like Safari's find.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onNext?()
        return false
    }
}
