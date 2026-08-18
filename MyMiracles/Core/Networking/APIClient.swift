import Foundation

/// The only way the app reaches the backend.
///
/// On Cloudflare there is no client-side database SDK and no database credential in the
/// bundle. Every read and write goes through the Worker API, which is where authorization
/// is decided (see `docs/architecture.md`). That removes an entire class of risk — the
/// client cannot craft a query — but it means this type is the whole surface, so it is
/// deliberately small.
nonisolated protocol APIClient: Sendable {
    func send<Response: Decodable & Sendable>(
        _ request: APIRequest<Response>
    ) async throws(AppError) -> Response
}

nonisolated enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

nonisolated struct APIRequest<Response: Decodable & Sendable>: Sendable {
    var method: HTTPMethod
    var path: String
    var query: [URLQueryItem]
    var body: Data?
    var requiresAuthentication: Bool
    /// Sent as `Idempotency-Key`. The Worker records it in `mutation_keys` and replays the
    /// original result rather than creating a second prayer when a phone retries.
    var idempotencyKey: String?

    init(
        method: HTTPMethod,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        requiresAuthentication: Bool = true,
        idempotencyKey: String? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.requiresAuthentication = requiresAuthentication
        self.idempotencyKey = idempotencyKey
    }
}

nonisolated extension APIRequest {
    static func get(_ path: String, query: [URLQueryItem] = []) -> APIRequest {
        APIRequest(method: .get, path: path, query: query)
    }

    /// Mutating requests carry an idempotency key by default. A person may be writing
    /// something heartfelt on a bad connection; a retry must never duplicate it.
    static func post(
        _ path: String,
        body: some Encodable & Sendable,
        idempotencyKey: String = UUID().uuidString
    ) throws(AppError) -> APIRequest {
        APIRequest(
            method: .post,
            path: path,
            body: try APICoding.encode(body),
            idempotencyKey: idempotencyKey
        )
    }
}

/// Supplies the bearer token for authenticated requests.
///
/// Phase 3 implements this over the Worker's session endpoints: a short-lived access token
/// plus a rotating refresh token held in the Keychain.
nonisolated protocol SessionTokenProvider: Sendable {
    /// A valid access token, refreshed if needed. `nil` when nobody is signed in.
    func accessToken() async throws(AppError) -> String?
}

/// Signed out. The default until Phase 3.
nonisolated struct AnonymousSessionTokenProvider: SessionTokenProvider {
    init() {}
    func accessToken() async throws(AppError) -> String? { nil }
}

/// Shared JSON configuration.
///
/// Timestamps are epoch **milliseconds** on both sides. D1 stores integers, the Worker
/// passes them through unchanged, and `Date` is decoded from the same number — so there is
/// exactly one time representation from SQLite row to SwiftUI view.
nonisolated enum APICoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func encode(_ value: some Encodable & Sendable) throws(AppError) -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            // The description of an encoding failure can quote the value being encoded,
            // which here means prayer or journal text. It goes in the redacted diagnostic.
            throw AppError(kind: .unexpected, diagnostic: String(describing: error))
        }
    }
}
