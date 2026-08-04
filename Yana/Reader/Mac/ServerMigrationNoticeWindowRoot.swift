import SwiftUI

/// Hosts `ServerMigrationNoticeView` in its own Mac window, mirroring `WelcomeWindowRoot`. If the
/// window is restored after the notice has already been dismissed (Mac Catalyst can restore
/// windows left open at last quit), it closes itself immediately.
struct ServerMigrationNoticeWindowRoot: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings()

    var body: some View {
        ServerMigrationNoticeView(onDismiss: {
            settings.hasDismissedServerMigrationNotice = true
            dismiss()
        })
        .toggleStyle(.switch)
        .onAppear {
            if settings.hasDismissedServerMigrationNotice { dismiss() }
        }
    }
}
