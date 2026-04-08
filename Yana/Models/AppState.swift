import Foundation

@MainActor
@Observable
final class AppState {
    // MARK: - Auth State

    var isAuthenticated = false
    var serverURL: String = ""
    var authToken: String = ""

    // MARK: - Article State

    var articles: [Article] = []
    var currentIndex: Int = 0
    var continuation: String?
    var hasMoreArticles: Bool = true

    // MARK: - Feed State

    var feeds: [Feed] = []

    // MARK: - UI State

    var isLoading = false
    var errorMessage: String?
    var showSettings = false

    // MARK: - Computed Properties

    var currentArticle: Article? {
        guard !articles.isEmpty, currentIndex >= 0, currentIndex < articles.count else {
            return nil
        }
        return articles[currentIndex]
    }

    var hasPreviousArticle: Bool {
        currentIndex > 0
    }

    var hasNextArticle: Bool {
        currentIndex < articles.count - 1 || hasMoreArticles
    }

    // MARK: - Init

    init() {
        loadCredentials()
    }

    // MARK: - Auth Methods

    func loadCredentials() {
        if let url = KeychainService.loadServerURL(),
           let token = KeychainService.loadAuthToken()
        {
            serverURL = url
            authToken = token
            isAuthenticated = true
        }
    }

    func login(serverURL: String, email: String, password: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let token = try await APIClient.login(
            serverURL: serverURL,
            email: email,
            password: password
        )

        KeychainService.saveCredentials(
            serverURL: serverURL,
            email: email,
            token: token
        )

        self.serverURL = serverURL
        self.authToken = token
        self.isAuthenticated = true
    }

    func logout() {
        KeychainService.clearAll()
        isAuthenticated = false
        serverURL = ""
        authToken = ""
        articles = []
        feeds = []
        currentIndex = 0
        continuation = nil
        hasMoreArticles = true
    }

    // MARK: - Data Loading

    func loadArticles() async {
        guard isAuthenticated else { return }
        isLoading = true
        errorMessage = nil

        do {
            let result = try await APIClient.fetchStreamContents(
                serverURL: serverURL,
                token: authToken
            )
            articles = result.articles
            continuation = result.continuation
            hasMoreArticles = result.continuation != nil
            currentIndex = 0
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func loadMoreArticles() async {
        guard isAuthenticated, let continuation, hasMoreArticles, !isLoading else { return }
        isLoading = true

        do {
            let result = try await APIClient.fetchStreamContents(
                serverURL: serverURL,
                token: authToken,
                continuation: continuation
            )
            articles.append(contentsOf: result.articles)
            self.continuation = result.continuation
            hasMoreArticles = result.continuation != nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Article Actions

    func markCurrentAsReadAndAdvance() async {
        guard let article = currentArticle else { return }

        // Mark as read locally
        if let index = articles.firstIndex(where: { $0.id == article.id }) {
            articles[index].read = true
        }

        // Mark as read on server (fire and forget)
        Task {
            try? await APIClient.markAsRead(
                serverURL: serverURL,
                token: authToken,
                articleIds: [article.numericId]
            )
        }

        // Advance to next
        if currentIndex < articles.count - 1 {
            currentIndex += 1
        } else if hasMoreArticles {
            await loadMoreArticles()
            if currentIndex < articles.count - 1 {
                currentIndex += 1
            }
        }
    }

    func goToPreviousArticle() {
        if currentIndex > 0 {
            currentIndex -= 1
        }
    }
}
