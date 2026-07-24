import SwiftData
import SwiftUI

/// Hosts `FeedEditorView` in its own Mac window. Replaces the sheet's create/edit closures: on
/// create it inserts (via FeedEditorView) then fetches the new feed itself; on edit it resolves the
/// feed from the shared context. Dismisses its own window when the editor finishes.
struct FeedEditorWindowRoot: View {
    let target: FeedEditorTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
        }
        .frame(minWidth: 520, minHeight: 600)
    }

    @ViewBuilder private var content: some View {
        switch target {
        case .create:
            FeedEditorView(feed: nil) { newFeed in
                ConfigSyncService.shared.requestPush()
                if newFeed.enabled {
                    UpdateActivity.shared.restart {
                        _ = await AggregationService(context: AppContainer.shared.mainContext)
                            .update(feed: newFeed)
                    }
                }
                dismiss()
            }
        case .edit(let id):
            if let feed = AppContainer.shared.mainContext.model(for: id) as? Feed {
                FeedEditorView(feed: feed)
            } else {
                // The feed was deleted before this window resolved it — nothing to edit.
                Color.clear.onAppear { dismiss() }
            }
        }
    }
}
