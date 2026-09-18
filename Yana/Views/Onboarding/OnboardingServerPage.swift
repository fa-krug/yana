import SwiftUI

/// Onboarding step 2: pair with a Yana Server. Reuses `DevicePairingView`'s WebView-based
/// sign-in flow (the same one Settings uses to re-pair) — this is just the entry point that
/// collects the server address and presents it as a sheet.
///
/// In the onboarding flow, the Skip/Continue button itself lives in `WelcomeView`'s shared
/// bottom footer, not in this page's `Form` — it reads "Skip for now" while unpaired and
/// "Continue" once pairing succeeds, driven by the shared `OnboardingServerState` both views
/// hold. "Skip for now" seeds the demo library (`ScreenshotSeed`, see
/// docs/superpowers/specs/2026-08-06-demo-data-seeding-design.md) and marks the device as
/// demo-mode (`AppSettings.hasSkippedServerPairing`) instead of pairing. If the user pairs a real
/// server later — either by returning here via "Show Welcome Screen Again" or via
/// `DemoModeBanner`'s "Pair Now" — the demo library is wiped before the first real sync runs.
struct OnboardingServerPage: View {
    let onPaired: () -> Void
    /// Settings' re-pair sheet (`ServerSettingsSection`) passes `false`: there's no onboarding
    /// flow to continue there, so pairing success should just close the sheet immediately rather
    /// than waiting for a second "Continue" tap, and there's no "Skip" affordance to show either.
    var isOnboardingFlow = true

    @State private var state: OnboardingServerState

    init(onPaired: @escaping () -> Void, isOnboardingFlow: Bool = true, state: OnboardingServerState = OnboardingServerState()) {
        self.onPaired = onPaired
        self.isOnboardingFlow = isOnboardingFlow
        self._state = State(initialValue: state)
    }

    @Environment(AppSettings.self) private var settings
    /// Needed only to hand `PairingSync` the pieces `InitialSyncGate` runs on, so the first sync
    /// against the newly paired server blocks behind `InitialSyncLoadingView` from here too --
    /// not just from the launch/onboarding-finish path in `ContentView`/`YanaApp`.
    @Environment(AppState.self) private var appState
    @Environment(ArticleStore.self) private var articleStore
    @State private var serverURLText = ""
    /// The server address this device is actually paired against. Editing the field away from
    /// this value resets `state.isPaired`, so changing the URL always reverts the form to "no
    /// login happened" rather than showing a stale success state for a server the field no
    /// longer points at.
    @State private var pairedURLText: String?
    @State private var isPairing = false
    @State private var pairingFailure: PairingFailure?
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        // Centered rather than top-aligned: this page's content is short (two small sections),
        // and pinning it to the top on a tall window (macOS, or an iPad in landscape) left
        // a big dead gap below it that read as broken. `GeometryReader` supplies the available
        // height so the content can center within it via `.frame(minHeight:alignment:)`, while
        // the `ScrollView` still keeps it reachable (rather than clipped) if a large Dynamic Type
        // size or a very short window ever makes it taller than that.
        Group {
            if isOnboardingFlow {
                // The wizard hands this page a full window pane, so it centers/top-aligns within
                // that height (see `contentAlignment`) and stays scrollable if it ever exceeds it.
                GeometryReader { proxy in
                    ScrollView {
                        content
                            .frame(minHeight: proxy.size.height, alignment: contentAlignment)
                    }
                }
            } else {
                // Settings' re-pair sheet instead sizes *itself* to this page. A `GeometryReader`
                // there reports the height it is proposed, which in a self-sizing Mac sheet is
                // zero -- and, once given one, leaves the content stranded at the top of a mostly
                // empty panel. Laying the content out directly lets the sheet hug it.
                content
            }
        }
        .accessibilityIdentifier("onboardingServerScreen")
        .onAppear {
            serverURLText = settings.serverBaseURL
            state.isPaired = AuthenticatedClient.current() != nil
            pairedURLText = state.isPaired ? serverURLText : nil
            state.performPrimaryAction = primaryAction
        }
        .onChange(of: serverURLText) { _, newValue in
            pairingFailure = nil
            if let pairedURLText, newValue != pairedURLText {
                state.isPaired = false
                self.pairedURLText = nil
            }
        }
        // Not a `.sheet`: `DevicePairingView`'s own body renders nothing (`Color.clear`) — its
        // only job is starting the coordinator, which presents `ASWebAuthenticationSession`'s
        // own system-level browser sheet. Wrapping that in a SwiftUI sheet just adds a second,
        // empty translucent card underneath it (visible on the Mac as a blank rounded panel
        // behind the real auth prompt) for no benefit — this way there's nothing of ours to show
        // at all until the system sheet appears.
        .background {
            if isPairing, let url = validatedServerURL {
                DevicePairingView(
                    serverBaseURL: url,
                    onPaired: { token in
                        settings.serverBaseURL = trimmedServerURLText
                        KeychainService.saveDeviceToken(token)
                        isPairing = false
                        isURLFieldFocused = false
                        settings.hasSkippedServerPairing = false
                        if isOnboardingFlow {
                            // Deferred to the "Continue" tap (`primaryAction`) — see its comment.
                            state.isPaired = true
                            pairedURLText = trimmedServerURLText
                        } else {
                            // No separate "Continue" step in Settings' re-pair sheet: pairing
                            // success IS the completion point, so reset + resync right here.
                            PairingSync.resetAndFullSync(
                                appState: appState, articleStore: articleStore, settings: settings
                            )
                            onPaired()
                        }
                    },
                    onCancel: { isPairing = false },
                    onFailed: { failure in
                        isPairing = false
                        pairingFailure = failure
                    }
                )
            }
        }
    }

    /// iOS centers this short page in the space below the header, because pinning it to the top
    /// of a tall window left a dead gap under it that read as broken. The Mac does the opposite:
    /// its window is taller still, and centering pushed the form so far from the header above it
    /// that the two stopped reading as one form. Top-aligned, the header and the fields group
    /// together and the slack collects above the footer, where a Mac wizard normally has it.
    private var contentAlignment: Alignment {
        #if os(macOS)
        .top
        #else
        .center
        #endif
    }

    private var content: some View {
        // No header here: in the onboarding flow, `WelcomeView.header` already draws the
        // icon/title/subtitle for this step, fixed in position across every step. The Settings
        // re-pair sheet (`isOnboardingFlow == false`) has no such header, which is why the field's
        // explanatory footnote below is restored for that case only -- in the onboarding flow it
        // would repeat the header subtitle word for word.
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Server Address")
                    .font(.subheadline.weight(.medium))
                serverAddressField
                if !trimmedServerURLText.isEmpty, validatedServerURL == nil {
                    Text(trimmedServerURLText.lowercased().hasPrefix("http")
                         ? "This doesn't look like a valid server address."
                         : "Enter a full address, including https://.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if !isOnboardingFlow {
                    Text("Yana needs a Yana Server to sign in and sync your feeds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                signInControl
                if let pairingFailure {
                    Text(Self.failureMessage(pairingFailure))
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if isOnboardingFlow, !state.isPaired {
                    Text("You'll see demo content until you pair a server. Pair anytime from Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 24)
        // In the wizard the content is a narrow column centered in a wide pane. In Settings'
        // sheet the panel *is* the column: capping and centering there left the fields indented
        // past the sheet's own title, which no Mac dialog does.
        .modifier(OnboardingContentWidth(isCentered: isOnboardingFlow))
    }

    /// AppKit draws a bordered text field itself, so the Mac uses the stock one; iOS has no
    /// equivalent built-in chrome inside a plain view, hence the hand-drawn field there.
    @ViewBuilder
    private var serverAddressField: some View {
        #if os(macOS)
        // `prompt:` renders AppKit's own placeholder inside the field's text area, correctly
        // inset -- an overlaid `Text` would sit at the container's leading edge instead. It is
        // `verbatim:` for the same reason the iOS overlay below is: a bare literal resolves to
        // `Text(LocalizedStringKey)`, whose Markdown pass autolinks a URL into link-blue.
        TextField("", text: $serverURLText, prompt: Text(verbatim: "https://your-server.example.com"))
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .autocorrectionDisabled()
            .focused($isURLFieldFocused)
            .onSubmit(signIn)
        #else
        card {
            // A plain `TextField` placeholder here renders link-blue, not the standard
            // gray placeholder color -- iOS auto-styles a `.keyboardType(.URL)` field's
            // placeholder as a hyperlink when the placeholder text itself parses as a
            // URL. An explicit overlay sidesteps that and always renders as a normal
            // gray placeholder.
            //
            // The overlay's own `Text(_:)` needs `verbatim:` too: a bare string
            // literal resolves to `Text(LocalizedStringKey)`, which Markdown-parses
            // its content -- and Markdown autolinks bare URLs, rendering this right
            // back in link-blue.
            ZStack(alignment: .leading) {
                if serverURLText.isEmpty {
                    Text(verbatim: "https://your-server.example.com")
                        .foregroundStyle(.secondary)
                }
                TextField("", text: $serverURLText)
                    // Software-keyboard hints, so iOS-only: the Mac has a hardware keyboard
                    // with no URL layout to switch to and no autocapitalization to suppress.
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isURLFieldFocused)
                    .submitLabel(.go)
                    .onSubmit(signIn)
            }
        }
        #endif
    }

    /// The Mac puts a push button at its natural width under the field it acts on; iOS keeps the
    /// full-width row this page has always used, which is the idiom there.
    @ViewBuilder
    private var signInControl: some View {
        if state.isPaired {
            Label("Signed in", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } else {
            #if os(macOS)
            Button("Sign In", action: signIn)
                .controlSize(.large)
                .disabled(validatedServerURL == nil)
            #else
            card {
                Button("Sign In", action: signIn)
                    .disabled(validatedServerURL == nil)
            }
            #endif
        }
    }

    #if !os(macOS)
    /// iOS has no built-in chrome for a control sitting in a plain view, so the field and the
    /// sign-in row draw their own grouped-row background. The Mac uses AppKit's own bordered
    /// text field and push button instead, and never calls this.
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    #endif

    /// `URL(string:)` alone isn't enough validation: a host-only address like
    /// "yana.example.com" (no scheme) parses successfully as a *relative* URL with a nil host,
    /// which `DevicePairing.pairingURL` then can't resolve against — the pairing sheet opens
    /// "about:blank" instead of failing loudly. Requiring an http/https scheme and a host catches
    /// that before it ever reaches the pairing flow.
    private var validatedServerURL: URL? {
        guard let url = URL(string: trimmedServerURLText),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    /// A pasted address often carries a trailing space or newline, which fails `URL(string:)`
    /// outright and used to surface the misleading "add https://" message even when the scheme
    /// was already there. Trimming here — and using this everywhere validation/persistence
    /// happens — means the raw `TextField` binding (`serverURLText`) stays untouched so the user
    /// can still see/edit exactly what they typed.
    private var trimmedServerURLText: String {
        serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lets the URL field's return key trigger the same action as tapping "Sign In", so pairing
    /// doesn't require reaching for the mouse/trackpad after typing the address.
    private func signIn() {
        guard validatedServerURL != nil else { return }
        pairingFailure = nil
        isPairing = true
    }

    /// User-facing copy for a genuine pairing failure (`.cancelled` never reaches here — it
    /// routes to `onCancel` and shows nothing, matching a user-initiated dismissal).
    static func failureMessage(_ failure: PairingFailure) -> String {
        switch failure {
        case .cancelled:
            return ""
        case .sessionFailed:
            return String(localized: "Sign-in didn't complete. Check that the address points to a running Yana Server and try again.")
        case .stateMismatch, .malformedCallback:
            return String(localized: "The server's response could not be verified. Please try signing in again.")
        }
    }

    /// While paired, this IS "Done" for the server-setup step: wipe whatever was mirrored before
    /// this pairing (stale demo/prior-server data) and kick off a full resync against the newly
    /// paired server, then advance.
    private func primaryAction() {
        if state.isPaired {
            PairingSync.resetAndFullSync(
                appState: appState, articleStore: articleStore, settings: settings
            )
            onPaired()
            return
        }
        state.isSkipping = true
        settings.hasSkippedServerPairing = true
        Task {
            await ScreenshotSeed.seed(into: AppContainer.shared.mainContext)
            state.isSkipping = false
            onPaired()
        }
    }
}

#Preview {
    OnboardingServerPage(onPaired: {})
        .environment(AppState())
        .environment(ArticleStore(container: AppContainer.shared))
        .environment(AppSettings())
}

/// Caps and centers the page's column in the onboarding wizard; fills the width, leading-aligned,
/// everywhere else. A `ViewModifier` rather than an `if` in the body so both branches keep the
/// same view identity and the field does not lose focus when the flag changes.
private struct OnboardingContentWidth: ViewModifier {
    let isCentered: Bool

    func body(content: Content) -> some View {
        if isCentered {
            content
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
