import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var appState: AppState

    @State private var serverURL: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?

    enum TestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $serverURL)
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
                        Task { await testAndSave() }
                    } label: {
                        HStack {
                            Text("Test Connection & Save")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(serverURL.isEmpty || email.isEmpty || password.isEmpty || isTesting)
                }

                if let testResult {
                    Section {
                        switch testResult {
                        case .success(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let message):
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                if appState.isAuthenticated {
                    Section {
                        Button("Logout", role: .destructive) {
                            appState.logout()
                            serverURL = ""
                            email = ""
                            password = ""
                            testResult = nil
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                serverURL = KeychainService.loadServerURL() ?? ""
                email = KeychainService.loadEmail() ?? ""
            }
        }
    }

    private func testAndSave() async {
        isTesting = true
        testResult = nil

        do {
            try await appState.login(
                serverURL: serverURL,
                email: email,
                password: password
            )

            let userInfo = try await APIClient.fetchUserInfo(
                serverURL: serverURL,
                token: appState.authToken
            )

            testResult = .success("Connected as \(userInfo.userName)")

            // Load articles after successful login
            await appState.loadArticles()
        } catch {
            testResult = .failure(error.localizedDescription)
        }

        isTesting = false
    }
}
