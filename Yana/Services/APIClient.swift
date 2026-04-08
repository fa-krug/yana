import Foundation

enum APIClient {

    // MARK: - Errors

    enum APIError: Error, LocalizedError {
        case invalidURL
        case authenticationFailed
        case serverError(Int)
        case networkError(Error)
        case decodingError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                String(localized: "Invalid server URL.")
            case .authenticationFailed:
                String(localized: "Authentication failed. Please check your credentials.")
            case .serverError(let code):
                String(localized: "Server returned an error (HTTP \(code)).")
            case .networkError(let error):
                String(localized: "Network error: \(error.localizedDescription)")
            case .decodingError(let error):
                String(localized: "Failed to parse server response: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Authentication

    /// Authenticate with the Yana server using email and password.
    /// Returns the auth token on success.
    static func login(serverURL: String, email: String, password: String) async throws -> String {
        let url = try buildURL(serverURL, path: AppConstants.greaderClientLogin)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedBody([
            ("Email", email),
            ("Passwd", password),
        ])

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(
                NSError(domain: "APIClient", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid response type",
                ])
            )
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.authenticationFailed
        }

        guard let body = String(data: data, encoding: .utf8) else {
            throw APIError.authenticationFailed
        }

        // Response is plain text with key=value lines; find the Auth= line
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("Auth=") {
                return String(line.dropFirst("Auth=".count))
            }
        }

        throw APIError.authenticationFailed
    }

    // MARK: - User Info

    /// Fetch information about the authenticated user.
    static func fetchUserInfo(serverURL: String, token: String) async throws -> GReaderUserInfo {
        let url = try buildURL(serverURL, path: AppConstants.greaderUserInfo)
        let request = authorizedRequest(url, token: token)
        return try await performJSONRequest(request)
    }

    // MARK: - Subscriptions

    /// Fetch the list of feed subscriptions and convert to domain `Feed` models.
    static func fetchSubscriptions(serverURL: String, token: String) async throws -> [Feed] {
        let url = try buildURL(serverURL, path: AppConstants.greaderSubscriptionList)
        let request = authorizedRequest(url, token: token)

        let list: GReaderSubscriptionList = try await performJSONRequest(request)

        return list.subscriptions.map { subscription in
            Feed(
                id: subscription.id,
                title: subscription.title,
                url: subscription.url,
                htmlUrl: subscription.htmlUrl ?? "",
                categories: subscription.categories.map { category in
                    FeedGroup(id: category.id, label: category.label)
                },
                unreadCount: 0
            )
        }
    }

    // MARK: - Unread Counts

    /// Fetch unread counts per feed/label.
    static func fetchUnreadCounts(serverURL: String, token: String) async throws -> [GReaderUnreadCount] {
        let url = try buildURL(serverURL, path: AppConstants.greaderUnreadCount)
        let request = authorizedRequest(url, token: token)

        let response: GReaderUnreadCountResponse = try await performJSONRequest(request)
        return response.unreadcounts
    }

    // MARK: - Stream Contents

    /// Fetch articles from the reading list stream.
    /// Returns a tuple of articles and an optional continuation token for pagination.
    static func fetchStreamContents(
        serverURL: String,
        token: String,
        excludeRead: Bool = true,
        count: Int = 50,
        continuation: String? = nil
    ) async throws -> (articles: [Article], continuation: String?) {
        var queryItems = [URLQueryItem(name: "n", value: String(count))]

        if excludeRead {
            queryItems.append(URLQueryItem(name: "xt", value: AppConstants.tagRead))
        }

        if let continuation {
            queryItems.append(URLQueryItem(name: "c", value: continuation))
        }

        let url = try buildURL(
            serverURL,
            path: AppConstants.greaderStreamContents,
            queryItems: queryItems
        )
        let request = authorizedRequest(url, token: token)

        let streamContents: GReaderStreamContents = try await performJSONRequest(request)

        let articles = streamContents.items.map { item in
            convertToArticle(item)
        }

        return (articles: articles, continuation: streamContents.continuation)
    }

    // MARK: - Edit Tags

    /// Mark the given articles as read.
    static func markAsRead(serverURL: String, token: String, articleIds: [String]) async throws {
        try await editTag(
            serverURL: serverURL,
            token: token,
            articleIds: articleIds,
            addTag: AppConstants.tagRead
        )
    }

    /// Mark the given articles as unread.
    static func markAsUnread(serverURL: String, token: String, articleIds: [String]) async throws {
        try await editTag(
            serverURL: serverURL,
            token: token,
            articleIds: articleIds,
            removeTag: AppConstants.tagRead
        )
    }

    /// Add or remove the starred tag on the given articles.
    static func toggleStar(
        serverURL: String,
        token: String,
        articleIds: [String],
        starred: Bool
    ) async throws {
        if starred {
            try await editTag(
                serverURL: serverURL,
                token: token,
                articleIds: articleIds,
                addTag: AppConstants.tagStarred
            )
        } else {
            try await editTag(
                serverURL: serverURL,
                token: token,
                articleIds: articleIds,
                removeTag: AppConstants.tagStarred
            )
        }
    }

    // MARK: - Private Helpers

    /// Build a full URL from the server base URL, a GReader API path, and optional query items.
    private static func buildURL(
        _ serverURL: String,
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) throws -> URL {
        let urlString = serverURL + AppConstants.greaderBasePath + path

        guard var components = URLComponents(string: urlString) else {
            throw APIError.invalidURL
        }

        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        return url
    }

    /// Create a GET request with the Google Reader auth header.
    private static func authorizedRequest(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("GoogleLogin auth=\(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Encode key-value pairs as application/x-www-form-urlencoded body data.
    /// Supports duplicate keys (e.g. multiple `i` parameters for article IDs).
    private static func formEncodedBody(_ params: [(String, String)]) -> Data {
        let encoded = params.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")

        return Data(encoded.utf8)
    }

    /// Perform a URLSession request, mapping transport errors to `APIError.networkError`.
    private static func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }
    }

    /// Perform a request and decode the JSON response to the given `Decodable` type.
    private static func performJSONRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await performRequest(request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw APIError.authenticationFailed
            }
            throw APIError.serverError(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// Post an edit-tag request to add or remove a tag on the given article IDs.
    private static func editTag(
        serverURL: String,
        token: String,
        articleIds: [String],
        addTag: String? = nil,
        removeTag: String? = nil
    ) async throws {
        let url = try buildURL(serverURL, path: AppConstants.greaderEditTag)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("GoogleLogin auth=\(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var params: [(String, String)] = []

        if let addTag {
            params.append(("a", addTag))
        }

        if let removeTag {
            params.append(("r", removeTag))
        }

        for articleId in articleIds {
            params.append(("i", articleId))
        }

        request.httpBody = formEncodedBody(params)

        let (_, response) = try await performRequest(request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw APIError.authenticationFailed
            }
            throw APIError.serverError(httpResponse.statusCode)
        }
    }

    /// Convert a `GReaderItem` from the API into a domain `Article`.
    private static func convertToArticle(_ item: GReaderItem) -> Article {
        let articleURL = item.alternate?.first?.href
            ?? item.canonical?.first?.href
            ?? ""

        let articleContent = item.content?.content
            ?? item.summary?.content
            ?? ""

        let published: Date = if let timestamp = item.published {
            Date(timeIntervalSince1970: TimeInterval(timestamp))
        } else {
            Date()
        }

        let isRead = item.categories?.contains(AppConstants.tagRead) ?? false
        let isStarred = item.categories?.contains(AppConstants.tagStarred) ?? false

        return Article(
            id: item.id,
            title: item.title ?? "",
            author: item.author ?? "",
            published: published,
            url: articleURL,
            content: articleContent,
            read: isRead,
            starred: isStarred,
            feedTitle: item.origin?.title ?? "",
            feedStreamId: item.origin?.streamId ?? "",
            feedHtmlUrl: item.origin?.htmlUrl ?? ""
        )
    }
}
