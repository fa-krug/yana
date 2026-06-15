import SwiftUI

struct ContentView: View {
    var appState: AppState

    var body: some View {
        ArticleReaderView(appState: appState)
    }
}
