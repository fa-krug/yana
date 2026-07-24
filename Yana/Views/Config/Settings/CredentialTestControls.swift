import SwiftUI

/// Per-section credential-test state shown in Settings.
enum TestStatus: Equatable {
    case idle
    case testing
    case valid
    case invalid(String)   // localized message
}

/// A "Test" button plus an inline status row, shared by every credential section
/// (Reddit, YouTube, each AI provider).
struct CredentialTestControls: View {
    let status: TestStatus
    let disabled: Bool
    let onClear: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text("Test")
                if status == .testing {
                    Spacer()
                    Text("Testing…").foregroundStyle(.secondary)
                    ProgressView()
                }
            }
        }
        .disabled(disabled || status == .testing)

        switch status {
        case .idle, .testing:
            EmptyView()
        case .valid:
            Label("Credentials valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid(let message):
            HStack {
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Spacer()
                Button("Clear", action: onClear).buttonStyle(.borderless)
            }
        }
    }
}

/// Runs an async credential test, threading its status through `setter`.
enum CredentialTest {
    @MainActor static func run(_ setter: @escaping (TestStatus) -> Void,
                              _ op: @escaping () async -> CredentialTestError?) {
        setter(.testing)
        Task {
            let error = await op()
            setter(error.map { .invalid($0.localizedMessage) } ?? .valid)
        }
    }
}
