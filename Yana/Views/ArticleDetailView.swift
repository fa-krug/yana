import SwiftUI

/// Read-only article screen shown when a search result is tapped. Reuses the shared body.
struct ArticleDetailView: View {
    let article: Article

    var body: some View {
        ArticleContentView(article: article)
            .navigationTitle(article.feed?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
    }
}
