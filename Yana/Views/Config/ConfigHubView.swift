import SwiftUI

/// Root of the library sheet. Links to Feeds, Tags, and Settings.
struct ConfigHubView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        FeedsView()
                    } label: {
                        Label("Feeds", systemImage: "list.bullet.rectangle")
                            .labelStyle(.tintedIcon(.orange))
                    }
                    NavigationLink {
                        TagsView()
                    } label: {
                        Label("Tags", systemImage: "tag")
                            .labelStyle(.tintedIcon(.pink))
                    }
                    NavigationLink {
                        ArticleListView()
                    } label: {
                        Label("Articles", systemImage: "magnifyingglass")
                            .labelStyle(.tintedIcon(.blue))
                    }
                } footer: {
                    Text("Organize your sources and browse everything you've collected.")
                }

                Section {
                    NavigationLink {
                        SettingsScreenView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .labelStyle(.tintedIcon(.gray))
                    }
                } footer: {
                    Text("Sources, AI, notifications, and library preferences.")
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Close"))
                }
            }
        }
    }
}
