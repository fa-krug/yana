import SwiftUI

/// Root of the configuration sheet. Links to Feeds, Tags, and Settings.
struct ConfigHubView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    FeedsView()
                } label: {
                    Label("Feeds", systemImage: "list.bullet.rectangle")
                }
                NavigationLink {
                    TagsView()
                } label: {
                    Label("Tags", systemImage: "tag")
                }
                NavigationLink {
                    ArticleListView()
                } label: {
                    Label("Articles", systemImage: "magnifyingglass")
                }
                NavigationLink {
                    SettingsScreenView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .navigationTitle("Configuration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
