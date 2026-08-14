import SwiftUI

/// New-article notification toggle, with a denied-permission alert.
struct NotificationsSettingsSection: View {
    @Environment(ArticleStore.self) private var store
    @Bindable private var settings = AppSettings()
    @State private var showNotificationDeniedAlert = false

    var body: some View {
        Section("Notifications") {
            Toggle(isOn: Binding(
                get: { settings.notificationsEnabled },
                set: { newValue in
                    if newValue {
                        Task {
                            let granted = await NotificationService.enable(.newArticles, settings: settings)
                            if !granted { showNotificationDeniedAlert = true }
                        }
                    } else {
                        settings.notificationsEnabled = false
                    }
                }
            )) {
                Label("Notify about new articles", systemImage: "bell.badge.fill")
                    .labelStyle(.tintedIcon(.red))
            }
            Toggle(isOn: Binding(
                get: { settings.showUnreadBadge },
                set: { newValue in
                    if newValue {
                        Task {
                            let granted = await NotificationService.enable(.unreadBadge, settings: settings)
                            UnreadBadgeUpdater.refresh(summaries: store.summaries, settings: settings)
                            if !granted { showNotificationDeniedAlert = true }
                        }
                    } else {
                        settings.showUnreadBadge = false
                        UnreadBadgeUpdater.refresh(summaries: store.summaries, settings: settings)
                    }
                }
            )) {
                Label("Show unread count on app icon", systemImage: "app.badge")
                    .labelStyle(.tintedIcon(.red))
            }
        }
        .alert("Notifications Disabled", isPresented: $showNotificationDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable notifications for Yana in the Settings app to get alerts about new articles.")
        }
    }
}
