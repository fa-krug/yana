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
    @State private var serverURLText = ""
    /// The server address this device is actually paired against. Editing the field away from
    /// this value resets `state.isPaired`, so changing the URL always reverts the form to "no
    /// login happened" rather than showing a stale success state for a server the field no
    /// longer points at.
    @State private var pairedURLText: String?
    @State private var isPairing = false
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        // Centered rather than top-aligned: this page's content is short (two small sections),
        // and pinning it to the top on a tall window (Mac Catalyst, or an iPad in landscape) left
        // a big dead gap below it that read as broken. `GeometryReader` supplies the available
        // height so the content can center within it via `.frame(minHeight:alignment:)`, while
        // the `ScrollView` still keeps it reachable (rather than clipped) if a large Dynamic Type
        // size or a very short window ever makes it taller than that.
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(minHeight: proxy.size.height, alignment: .center)
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
            if let pairedURLText, newValue != pairedURLText {
                state.isPaired = false
                self.pairedURLText = nil
            }
        }
        // Not a `.sheet`: `DevicePairingView`'s own body renders nothing (`Color.clear`) — its
        // only job is starting the coordinator, which presents `ASWebAuthenticationSession`'s
        // own system-level browser sheet. Wrapping that in a SwiftUI sheet just adds a second,
        // empty translucent card underneath it (visible on Mac Catalyst as a blank rounded panel
        // behind the real auth prompt) for no benefit — this way there's nothing of ours to show
        // at all until the system sheet appears.
        .background {
            if isPairing, let url = validatedServerURL {
                DevicePairingView(
                    serverBaseURL: url,
                    onPaired: { token in
                        settings.serverBaseURL = serverURLText
                        KeychainService.saveDeviceToken(token)
                        isPairing = false
                        isURLFieldFocused = false
                        settings.hasSkippedServerPairing = false
                        if isOnboardingFlow {
                            // Deferred to the "Continue" tap (`primaryAction`) — see its comment.
                            state.isPaired = true
                            pairedURLText = serverURLText
                        } else {
                            // No separate "Continue" step in Settings' re-pair sheet: pairing
                            // success IS the completion point, so reset + resync right here.
                            PairingSync.resetAndFullSync()
                            onPaired()
                        }
                    },
                    onCancel: { isPairing = false }
                )
            }
        }
    }

    private var content: some View {
        // No header here: in the onboarding flow, `WelcomeView.header` already draws the
        // icon/title/subtitle for this step, fixed in position across every step. The Settings
        // re-pair sheet (`isOnboardingFlow == false`) has no such header, which is why the footer
        // text below is unconditional rather than gated on `isOnboardingFlow`.
        VStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Server Address")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                card {
                    // A plain `TextField` placeholder here renders link-blue, not the standard
                    // gray placeholder color — iOS auto-styles a `.keyboardType(.URL)` field's
                    // placeholder as a hyperlink when the placeholder text itself parses as a
                    // URL. An explicit overlay sidesteps that and always renders as a normal
                    // gray placeholder.
                    //
                    // The overlay's own `Text(_:)` needs `verbatim:` too: a bare string
                    // literal resolves to `Text(LocalizedStringKey)`, which Markdown-parses
                    // its content — and Markdown autolinks bare URLs, rendering this right
                    // back in link-blue.
                    ZStack(alignment: .leading) {
                        if serverURLText.isEmpty {
                            Text(verbatim: "https://your-server.example.com")
                                .foregroundStyle(.secondary)
                        }
                        TextField("", text: $serverURLText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isURLFieldFocused)
                            .submitLabel(.go)
                            .onSubmit(signIn)
                    }
                }
                if !serverURLText.isEmpty, validatedServerURL == nil {
                    Text("Enter a full address, including https://.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                } else {
                    Text("Yana needs a Yana Server to sign in and sync your feeds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                card {
                    if state.isPaired {
                        Label("Signed in", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Button("Sign In", action: signIn)
                            .disabled(validatedServerURL == nil)
                    }
                }
                if isOnboardingFlow, !state.isPaired {
                    Text("You'll see demo content until you pair a server. Pair anytime from Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// `URL(string:)` alone isn't enough validation: a host-only address like
    /// "yana.example.com" (no scheme) parses successfully as a *relative* URL with a nil host,
    /// which `DevicePairing.pairingURL` then can't resolve against — the pairing sheet opens
    /// "about:blank" instead of failing loudly. Requiring an http/https scheme and a host catches
    /// that before it ever reaches the pairing flow.
    private var validatedServerURL: URL? {
        guard let url = URL(string: serverURLText),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    /// Lets the URL field's return key trigger the same action as tapping "Sign In", so pairing
    /// doesn't require reaching for the mouse/trackpad after typing the address.
    private func signIn() {
        guard validatedServerURL != nil else { return }
        isPairing = true
    }

    /// While paired, this IS "Done" for the server-setup step: wipe whatever was mirrored before
    /// this pairing (stale demo/prior-server data) and kick off a full resync against the newly
    /// paired server, then advance.
    private func primaryAction() {
        if state.isPaired {
            PairingSync.resetAndFullSync()
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
        .environment(AppSettings())
}
