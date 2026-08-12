import Foundation
import Testing
@testable import Yana

@Suite("ManagementWebView.webviewSessionURL")
struct ManagementWebViewURLTests {
    @Test func buildsTheBootstrapURLWithTokenAndNext() {
        let url = ManagementWebView.webviewSessionURL(
            serverBaseURL: URL(string: "https://my-yana.example.com")!,
            token: "abc123",
            next: "/feeds/new"
        )
        #expect(url.scheme == "https")
        #expect(url.host == "my-yana.example.com")
        #expect(url.path == "/webview-session")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value) })
        #expect(query["token"] == "abc123")
        #expect(query["next"] == "/feeds/new")
    }
}

private struct StubMintTokenFailure: Error {}

@Suite("ManagementWebView.loadURL")
struct ManagementWebViewLoadURLTests {
    @Test @MainActor func mintTokenSuccessReturnsTheBootstrapURL() async {
        let serverBaseURL = URL(string: "https://my-yana.example.com")!
        let url = await ManagementWebView.loadURL(serverBaseURL: serverBaseURL, path: "/feeds") {
            "abc123"
        }
        let expected = ManagementWebView.webviewSessionURL(
            serverBaseURL: serverBaseURL, token: "abc123", next: "/feeds"
        )
        #expect(url == expected)
    }

    @Test func mintTokenFailureFallsBackToThePlainPathURL() async {
        let serverBaseURL = URL(string: "https://my-yana.example.com")!
        let url = await ManagementWebView.loadURL(serverBaseURL: serverBaseURL, path: "/feeds") {
            throw StubMintTokenFailure()
        }
        #expect(url == serverBaseURL.appendingPathComponent("/feeds"))
    }
}
