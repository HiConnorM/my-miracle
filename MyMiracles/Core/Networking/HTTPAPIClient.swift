import Foundation

/// `URLSession` implementation of ``APIClient``.
///
/// The app has no third-party networking dependency (rule 18) — `URLSession` does
/// everything needed, including background-friendly retry behavior later.
nonisolated struct HTTPAPIClient: APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokens: any SessionTokenProvider
    private let logger: any AppLogger

    init(
        baseURL: URL,
        session: URLSession = .shared,
        tokens: any SessionTokenProvider,
        logger: any AppLogger
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokens = tokens
        self.logger = logger
    }

    func send<Response: Decodable & Sendable>(
        _ request: APIRequest<Response>
    ) async throws(AppError) -> Response {
        let urlRequest = try await makeURLRequest(for: request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            let mapped = AppError.unexpected(error)
            logger.warning(
                "request failed before a response",
                category: .network,
                metadata: ["kind": .symbol("transport"), "path": .redacted]
            )
            throw mapped
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError(kind: .unexpected, diagnostic: "non-HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data)
        }

        // A 204 with an empty body is a legitimate success for `Void`-shaped responses.
        if data.isEmpty, let empty = EmptyResponse() as? Response {
            return empty
        }

        do {
            return try APICoding.decoder.decode(Response.self, from: data)
        } catch {
            logger.error(
                "response could not be decoded",
                category: .network,
                metadata: ["status": .int(http.statusCode)]
            )
            // A decoding error quotes the payload, which is user content. Redacted.
            throw AppError(kind: .unexpected, diagnostic: String(describing: error))
        }
    }

    private func makeURLRequest<Response>(
        for request: APIRequest<Response>
    ) async throws(AppError) -> URLRequest {
        guard
            var components = URLComponents(
                url: baseURL.appending(path: request.path),
                resolvingAgainstBaseURL: false
            )
        else {
            throw AppError(kind: .configuration, diagnostic: "invalid base URL")
        }
        if !request.query.isEmpty {
            components.queryItems = request.query
        }
        guard let url = components.url else {
            throw AppError(kind: .configuration, diagnostic: "invalid request URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let key = request.idempotencyKey {
            urlRequest.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        }
        if request.requiresAuthentication {
            guard let token = try await tokens.accessToken() else {
                throw AppError(kind: .notAuthenticated)
            }
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    /// Maps a Worker response onto the app's error vocabulary.
    ///
    /// A 403 is usually the authorization layer correctly refusing — a private post, a
    /// block, someone else's journal. That is a correct outcome, not a bug to route
    /// around (rule 6).
    static func error(status: Int, body: Data) -> AppError {
        let kind: AppError.Kind = switch status {
        case 401: .notAuthenticated
        case 403: .permissionDenied
        case 404: .notFound
        case 409: .conflict
        case 429: .rateLimited
        case 500...599: .server
        default: .unexpected
        }
        // The server's detail string may quote submitted content, so it is only ever a
        // redacted diagnostic — never shown to the person.
        return AppError(kind: kind, diagnostic: String(data: body, encoding: .utf8))
    }
}

/// Decodes from an empty body, for endpoints that return 204.
nonisolated struct EmptyResponse: Codable, Sendable {
    init() {}
}
