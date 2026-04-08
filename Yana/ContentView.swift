import SwiftUI

struct ContentView: View {
    var appState: AppState

    var body: some View {
        if appState.isAuthenticated {
            ArticleReaderView(appState: appState)
        } else {
            LoginView(appState: appState)
        }
    }
}

struct LoginView: View {
    var appState: AppState
    @State private var serverURL = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.up.forward")
                            .font(.system(size: 48))
                            .foregroundStyle(.tint)

                        Text("Yana")
                            .font(.largeTitle.bold())

                        Text("Connect to your Yana server to get started.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                    .listRowBackground(Color.clear)
                }

                Section("Server") {
                    TextField("https://yana.example.com", text: $serverURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section("Credentials") {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }

                Section {
                    Button {
                        Task { await login() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoggingIn {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text("Sign In")
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(serverURL.isEmpty || email.isEmpty || password.isEmpty || isLoggingIn)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Welcome")
        }
    }

    private func login() async {
        isLoggingIn = true
        errorMessage = nil

        do {
            try await appState.login(
                serverURL: serverURL,
                email: email,
                password: password
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoggingIn = false
    }
}
