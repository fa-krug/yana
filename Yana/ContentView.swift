import SwiftUI

struct ContentView: View {
    var appState: AppState

    var body: some View {
        ReaderScreen(appState: appState)
    }
}
