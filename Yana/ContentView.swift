import SwiftUI

struct ContentView: View {
    var appState: AppState

    /// Owns the timeline window size so it survives `ReaderScreen` re-inits when the window grows.
    @State private var timelineLimit = TimelineWindow.pageSize

    var body: some View {
        ReaderScreen(appState: appState, limit: timelineLimit) {
            timelineLimit = TimelineWindow.nextLimit(timelineLimit)
        }
    }
}
