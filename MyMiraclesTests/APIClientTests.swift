import Foundation
import Testing
@testable import MyMiracles

/// The Worker is the only authorization boundary in the Cloudflare architecture, so the
/// client's job is to report its answers faithfully — especially the refusals.
@Suite("API error mapping")
nonisolated struct APIErrorMappingTests {
    @Test(
        "HTTP status maps to the app's error vocabulary",
        arguments: [
            (401, AppError.Kind.notAuthenticated),
            (403, .permissionDenied),
            (404, .notFound),
            (409, .conflict),
            (429, .rateLimited),
            (500, .server),
            (503, .server),
            (418, .unexpected),
        ]
    )
    func statusMapping(status: Int, expected: AppError.Kind) {
        #expect(HTTPAPIClient.error(status: status, body: Data()).kind == expected)
    }

    /// A 403 means the Worker's authorization layer said no — a private post, a block,
    /// someone else's journal. Presenting that as retryable would invite a retry loop
    /// against a correct decision (rule 6).
    @Test("A refusal is terminal, not retryable")
    func refusalIsTerminal() {
        let refused = HTTPAPIClient.error(status: 403, body: Data())
        #expect(!refused.isRetryable)
        #expect(!refused.isPending)
    }

    @Test("Server failures stay retryable")
    func serverFailuresRetryable() {
        #expect(HTTPAPIClient.error(status: 500, body: Data()).isRetryable)
        #expect(HTTPAPIClient.error(status: 429, body: Data()).isRetryable)
    }

    /// Worker error payloads can quote the submitted body, which in this app is prayer
    /// text. It must land in the redacted diagnostic and never in what the person reads.
    @Test("A server error body never reaches the user-facing message")
    func serverDetailIsRedacted() {
        let body = Data(#"{"error":"invalid","detail":"body=Please pray for my marriage."}"#.utf8)
        let error = HTTPAPIClient.error(status: 422, body: body)

        #expect(error.diagnostic?.description == "<redacted>")
        #expect(!error.message.contains("marriage"))
        #expect(!error.title.contains("marriage"))
    }
}

@Suite("API request construction")
nonisolated struct APIRequestTests {
    struct Draft: Encodable, Sendable {
        let body: String
        let visibility: String
    }

    @Test("Reads are unauthenticated-safe and carry no idempotency key")
    func getRequest() {
        let request = APIRequest<EmptyResponse>.get("/v1/feed", query: [.init(name: "limit", value: "25")])

        #expect(request.method == .get)
        #expect(request.path == "/v1/feed")
        #expect(request.idempotencyKey == nil)
        #expect(request.query.first?.value == "25")
    }

    /// Someone may write for ten minutes on a bad connection. A retry must replay, not
    /// duplicate — so every mutation carries a key by default rather than opting in.
    @Test("Mutations carry an idempotency key by default")
    func postRequestIsIdempotent() throws {
        let request = try APIRequest<EmptyResponse>.post(
            "/v1/posts",
            body: Draft(body: "Please pray for my marriage.", visibility: "public")
        )

        #expect(request.method == .post)
        #expect(request.idempotencyKey != nil)
        #expect(request.requiresAuthentication)
        #expect(request.body != nil)
    }

    @Test("An explicit key survives, so a retry reuses the original")
    func explicitIdempotencyKey() throws {
        let key = "fixed-key-0001"
        let request = try APIRequest<EmptyResponse>.post(
            "/v1/posts",
            body: Draft(body: "x", visibility: "private"),
            idempotencyKey: key
        )
        #expect(request.idempotencyKey == key)
    }

    /// D1 stores epoch milliseconds, the Worker passes them through, and the client
    /// decodes the same number. One time representation, end to end.
    @Test("Dates are encoded as epoch milliseconds")
    func datesAreMilliseconds() throws {
        struct Stamped: Codable, Sendable { let at: Date }

        let encoded = try APICoding.encode(Stamped(at: Date(timeIntervalSince1970: 1_785_283_200)))
        #expect(String(data: encoded, encoding: .utf8)?.contains("1785283200000") == true)

        let decoded = try APICoding.decoder.decode(Stamped.self, from: encoded)
        #expect(decoded.at.timeIntervalSince1970 == 1_785_283_200)
    }

    @Test("A signed-out session provides no token")
    func anonymousProviderHasNoToken() async throws {
        #expect(try await AnonymousSessionTokenProvider().accessToken() == nil)
    }
}
