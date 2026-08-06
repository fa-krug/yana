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

    @State private var settings = AppSettings()
    @State private var serverURLText = ""
    /// The server address this device is actually paired against. Editing the field away from
    /// this value resets `state.isPaired`, so changing the URL always reverts the form to "no
    /// login happened" rather than showing a stale success state for a server the field no
    /// longer points at.
    @State private var pairedURLText: String?
    @State private var isPairing = false
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                // A plain `TextField` placeholder here renders link-blue, not the standard gray
                // placeholder color — iOS auto-styles a `.keyboardType(.URL)` field's placeholder
                // as a hyperlink when the placeholder text itself parses as a URL. An explicit
                // overlay sidesteps that and always renders as a normal gray placeholder.
                //
                // The overlay's own `Text(_:)` needs `verbatim:` too: a bare string literal
                // resolves to `Text(LocalizedStringKey)`, which Markdown-parses its content —
                // and Markdown autolinks bare URLs, rendering this right back in link-blue.
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
                }
            } header: {
                Text("Server Address")
            } footer: {
                Text("Yana needs a Yana Server to sign in and sync your feeds.")
            }

            Section {
                if state.isPaired {
                    Label("Signed in", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Sign In") { isPairing = true }
                        .disabled(URL(string: serverURLText) == nil)
                }
            } footer: {
                if isOnboardingFlow, !state.isPaired {
                    Text("You'll see demo content until you pair a server. Pair anytime from Settings.")
                }
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
        .sheet(isPresented: $isPairing) {
            if let url = URL(string: serverURLText) {
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
}
