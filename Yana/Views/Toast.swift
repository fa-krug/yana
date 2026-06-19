import SwiftUI

/// Visual variant for a transient toast: neutral info vs. a tinted error.
enum ToastStyle: Equatable {
    case info
    case error
}

/// A transient status message shown as an auto-dismissing capsule at the top of the screen.
struct ToastMessage: Equatable {
    var text: String
    var style: ToastStyle = .info
}

private struct ToastModifier: ViewModifier {
    @Binding var message: ToastMessage?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    Text(message.text)
                        .font(.subheadline)
                        .foregroundStyle(message.style == .error ? Color.white : Color.primary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background {
                            if message.style == .error {
                                Capsule().fill(Color.red)
                            } else {
                                Capsule().fill(.thinMaterial)
                            }
                        }
                        .clipShape(Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: message) {
                            AccessibilityNotification.Announcement(message.text).post()
                            let dismissAfter: Double = message.style == .error ? 4 : 2.5
                            try? await Task.sleep(for: .seconds(dismissAfter))
                            self.message = nil
                        }
                }
            }
            .animation(.snappy, value: message)
    }
}

extension View {
    /// Presents `message` as a transient toast that auto-dismisses after 2.5s and clears the binding.
    func toast(_ message: Binding<ToastMessage?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}
