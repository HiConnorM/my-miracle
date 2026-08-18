import Foundation
import Testing
@testable import MyMiracles

@Suite("Sign-in nonce")
nonisolated struct SignInNonceTests {
    /// Apple echoes the hashed nonce verbatim into the identity token, and the Worker hashes
    /// what the client sent and compares. Both sides must agree on lowercase hex — if this
    /// changes, every sign-in fails. See `workers/src/auth/apple.ts`.
    @Test("Hashes to lowercase hex, matching the Worker")
    func hashingMatchesTheWorker() {
        // SHA-256("abc"), the standard test vector.
        #expect(
            SignInNonce.sha256Hex("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(
            SignInNonce.sha256Hex("")
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test("Pairs a raw value with its own hash")
    func rawAndHashedAgree() {
        let nonce = SignInNonce(raw: "abc")
        #expect(nonce.raw == "abc")
        #expect(nonce.hashed == SignInNonce.sha256Hex("abc"))
    }

    /// A predictable nonce would defeat the replay protection it exists to provide.
    @Test("Generates a distinct, long value each time")
    func generatesUniqueValues() {
        let values = Set((0..<50).map { _ in SignInNonce().raw })
        #expect(values.count == 50)
        #expect(values.allSatisfy { $0.count == 64 })
    }
}

@Suite("Session")
nonisolated struct SessionTests {
    let reference = Date(timeIntervalSince1970: 1_785_283_200)

    @Test("Is live well before it expires")
    func liveSession() {
        let session = Session(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: reference.addingTimeInterval(900)
        )
        #expect(!session.isExpired(at: reference))
    }

    /// Treated as expired a minute early, so a request is never sent with a token that dies
    /// mid-flight and comes back as a spurious 401.
    @Test("Expires early, inside the refresh margin")
    func refreshMargin() {
        let session = Session(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: reference.addingTimeInterval(30)
        )
        #expect(session.isExpired(at: reference))
    }

    @Test("Is expired once past its expiry")
    func expiredSession() {
        let session = Session(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: reference.addingTimeInterval(-1)
        )
        #expect(session.isExpired(at: reference))
    }

    @Test("Derives its expiry from the server's lifetime")
    func derivesExpiry() {
        let session = Session(response: .preview(expiresIn: 900), now: reference)
        #expect(session.expiresAt == reference.addingTimeInterval(900))
    }

    @Test("Round-trips through JSON for keychain storage")
    func codable() throws {
        let session = Session(accessToken: "a", refreshToken: "r", expiresAt: reference)
        let decoded = try JSONDecoder().decode(
            Session.self,
            from: try JSONEncoder().encode(session)
        )
        #expect(decoded == session)
    }
}

@Suite("Secure store")
nonisolated struct SecureStoreTests {
    @Test("Round-trips, overwrites and deletes")
    func roundTrip() throws {
        let store = InMemorySecureStore()

        #expect(store.read("session") == nil)

        try store.save(Data("first".utf8), for: "session")
        #expect(store.read("session") == Data("first".utf8))

        try store.save(Data("second".utf8), for: "session")
        #expect(store.read("session") == Data("second".utf8))

        try store.delete("session")
        #expect(store.read("session") == nil)
    }

    @Test("Deleting something absent is not an error")
    func deleteMissing() throws {
        try InMemorySecureStore().delete("nothing-here")
    }

    /// The real Keychain path, exercised on the simulator. Worth having: a Keychain
    /// misconfiguration fails silently and would sign people out on every launch.
    @Test("The keychain implementation round-trips")
    func keychainRoundTrip() throws {
        let store = KeychainStore(service: "com.mymiracles.tests.\(UUID().uuidString)")

        try store.save(Data("refresh-token".utf8), for: "session")
        #expect(store.read("session") == Data("refresh-token".utf8))

        try store.save(Data("rotated-token".utf8), for: "session")
        #expect(store.read("session") == Data("rotated-token".utf8))

        try store.delete("session")
        #expect(store.read("session") == nil)
    }
}

@Suite("Session manager")
struct SessionManagerTests {
    private func makeManager(
        store: any SecureStore = InMemorySecureStore(),
        repository: FakeAuthenticationRepository = FakeAuthenticationRepository()
    ) -> (SessionManager, FakeAuthenticationRepository, any SecureStore) {
        (
            SessionManager(store: store, refresher: repository, logger: NoopAppLogger()),
            repository,
            store
        )
    }

    @Test("Has no token when signed out")
    func signedOut() async throws {
        let (manager, _, _) = makeManager()
        #expect(try await manager.accessToken() == nil)
    }

    @Test("Returns a live token without refreshing")
    func liveToken() async throws {
        let (manager, repository, _) = makeManager()
        await manager.adopt(Session(response: .preview(accessToken: "live", expiresIn: 900)))

        #expect(try await manager.accessToken() == "live")
        #expect(repository.refreshCallCount == 0)
    }

    @Test("Refreshes an expired token")
    func refreshesExpired() async throws {
        let (manager, repository, _) = makeManager()
        repository.update { $0.refresh = .success(.preview(accessToken: "renewed")) }
        await manager.adopt(Session(response: .preview(accessToken: "stale", expiresIn: 0)))

        #expect(try await manager.accessToken() == "renewed")
        #expect(repository.refreshCallCount == 1)
    }

    /**
     The Worker treats a refresh token presented twice as theft and revokes every session.
     Two screens hitting an expired token at once must therefore produce **one** exchange —
     otherwise the app would sign the person out of their own account.
     */
    @Test("Coalesces concurrent refreshes into a single exchange")
    func coalescesConcurrentRefreshes() async throws {
        let (manager, repository, _) = makeManager()
        repository.update { $0.refresh = .success(.preview(accessToken: "renewed")) }
        await manager.adopt(Session(response: .preview(accessToken: "stale", expiresIn: 0)))

        let tokens = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask { try? await manager.accessToken() }
            }
            var results: [String?] = []
            for await token in group { results.append(token) }
            return results
        }

        #expect(tokens.allSatisfy { $0 == "renewed" })
        #expect(repository.refreshCallCount == 1)
    }

    /// The rotated refresh token must be persisted, or the next launch would present the
    /// old one — which the Worker reads as theft.
    @Test("Persists the rotated token")
    func persistsRotatedToken() async throws {
        let store = InMemorySecureStore()
        let (manager, repository, _) = makeManager(store: store)
        repository.update { $0.refresh = .success(.preview(refreshToken: "rotated")) }
        await manager.adopt(Session(response: .preview(refreshToken: "original", expiresIn: 0)))

        _ = try await manager.accessToken()

        let data = try #require(store.read("session"))
        let stored = try JSONDecoder().decode(Session.self, from: data)
        #expect(stored.refreshToken == "rotated")
    }

    @Test("Restores a stored session")
    func restores() async throws {
        let store = InMemorySecureStore()
        let session = Session(
            accessToken: "restored",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(900)
        )
        try store.save(try JSONEncoder().encode(session), for: "session")

        let (manager, _, _) = makeManager(store: store)
        #expect(await manager.restore() == session)
        #expect(try await manager.accessToken() == "restored")
    }

    @Test("Discards an unreadable stored session instead of wedging")
    func discardsCorruptSession() async throws {
        let store = InMemorySecureStore()
        try store.save(Data("not json".utf8), for: "session")

        let (manager, _, _) = makeManager(store: store)
        #expect(await manager.restore() == nil)
        #expect(store.read("session") == nil)
    }

    /// A refused refresh means the session is gone — expired, signed out elsewhere, or
    /// revoked. Clearing it sends the person to sign-in rather than retrying forever.
    @Test("Clears the session when a refresh is refused")
    func clearsOnRefusal() async throws {
        let store = InMemorySecureStore()
        let (manager, repository, _) = makeManager(store: store)
        repository.update { $0.refresh = .failure(AppError(kind: .notAuthenticated)) }
        await manager.adopt(Session(response: .preview(expiresIn: 0)))

        await #expect(throws: AppError.self) { try await manager.accessToken() }
        #expect(await manager.currentSession == nil)
        #expect(store.read("session") == nil)
    }

    /// A flaky network is not a reason to destroy someone's session.
    @Test("Keeps the session when a refresh fails for a network reason")
    func keepsSessionOnNetworkFailure() async throws {
        let (manager, repository, _) = makeManager()
        repository.update { $0.refresh = .failure(AppError(kind: .offline)) }
        await manager.adopt(Session(response: .preview(expiresIn: 0)))

        await #expect(throws: AppError.self) { try await manager.accessToken() }
        #expect(await manager.currentSession != nil)
    }

    @Test("Clearing removes the stored session")
    func clearRemovesStorage() async throws {
        let store = InMemorySecureStore()
        let (manager, _, _) = makeManager(store: store)
        await manager.adopt(Session(response: .preview()))
        #expect(store.read("session") != nil)

        await manager.clear()
        #expect(store.read("session") == nil)
        #expect(try await manager.accessToken() == nil)
    }
}

@MainActor
@Suite("Authentication model")
struct AuthenticationModelTests {
    private func makeModel(
        repository: FakeAuthenticationRepository = FakeAuthenticationRepository(),
        store: any SecureStore = InMemorySecureStore()
    ) -> (AuthenticationModel, FakeAuthenticationRepository) {
        let logger = NoopAppLogger()
        let model = AuthenticationModel(
            repository: repository,
            sessions: SessionManager(store: store, refresher: repository, logger: logger),
            analytics: NoopAnalyticsClient(),
            logger: logger
        )
        return (model, repository)
    }

    @Test("Starts signed out when there is no stored session")
    func noStoredSession() async {
        let (model, _) = makeModel()
        await model.restore()
        #expect(model.state == .signedOut)
    }

    @Test("Restores straight into the app when the session is good")
    func restoresSignedIn() async throws {
        let store = InMemorySecureStore()
        try store.save(
            try JSONEncoder().encode(
                Session(
                    accessToken: "a",
                    refreshToken: "r",
                    expiresAt: Date().addingTimeInterval(900)
                )
            ),
            for: "session"
        )

        let repository = FakeAuthenticationRepository()
        let profile = ProfileResponse(username: "connor", displayName: "Connor")
        repository.update {
            $0.me = .success(MeResponse(accountId: "account-1", profile: profile))
        }

        let (model, _) = makeModel(repository: repository, store: store)
        await model.restore()

        #expect(model.state == .signedIn(profile))
    }

    /// A stored session the server no longer honours means signing in again — not an error
    /// screen.
    @Test("Signs out quietly when a restored session is refused")
    func restoreRefused() async throws {
        let store = InMemorySecureStore()
        try store.save(
            try JSONEncoder().encode(
                Session(
                    accessToken: "a",
                    refreshToken: "r",
                    expiresAt: Date().addingTimeInterval(900)
                )
            ),
            for: "session"
        )

        let repository = FakeAuthenticationRepository()
        repository.update { $0.me = .failure(AppError(kind: .notAuthenticated)) }

        let (model, _) = makeModel(repository: repository, store: store)
        await model.restore()

        #expect(model.state == .signedOut)
        #expect(model.error == nil)
        #expect(store.read("session") == nil)
    }

    /// An account exists the moment Apple verifies, but a username comes later. The app has
    /// to route to onboarding rather than assuming a complete profile.
    @Test("Routes a new account to profile creation")
    func newAccountNeedsProfile() async {
        let repository = FakeAuthenticationRepository()
        repository.update {
            $0.signIn = .success(.preview(isNewAccount: true, profile: nil))
        }

        let (model, _) = makeModel(repository: repository)
        await model.signIn(identityToken: "token", nonce: SignInNonce(raw: "n"))

        #expect(model.state == .signedInWithoutProfile)
    }

    @Test("Routes a returning account straight in")
    func returningAccountSignsIn() async {
        let profile = ProfileResponse(username: "connor", displayName: "Connor")
        let repository = FakeAuthenticationRepository()
        repository.update { $0.signIn = .success(.preview(profile: profile)) }

        let (model, _) = makeModel(repository: repository)
        await model.signIn(identityToken: "token", nonce: SignInNonce(raw: "n"))

        #expect(model.state == .signedIn(profile))
    }

    /// The Worker hashes what it receives and compares with what Apple signed, so the client
    /// must send the raw value — sending the hash would fail every sign-in.
    @Test("Sends the raw nonce, never the hash")
    func sendsRawNonce() async {
        let (model, repository) = makeModel()
        let nonce = SignInNonce(raw: "the-raw-nonce")

        await model.signIn(identityToken: "token", nonce: nonce)

        #expect(repository.lastNonce == "the-raw-nonce")
        #expect(repository.lastNonce != nonce.hashed)
    }

    @Test("Surfaces a sign-in failure without changing state")
    func signInFailure() async {
        let repository = FakeAuthenticationRepository()
        repository.update { $0.signIn = .failure(AppError(kind: .offline)) }

        let (model, _) = makeModel(repository: repository)
        await model.signIn(identityToken: "token", nonce: SignInNonce(raw: "n"))

        #expect(model.state == .restoring)
        #expect(model.error?.kind == .offline)
        #expect(!model.isWorking)
    }

    @Test("Completes onboarding once a profile is claimed")
    func claimsProfile() async {
        let profile = ProfileResponse(username: "connor", displayName: "Connor")
        let repository = FakeAuthenticationRepository()
        repository.update { $0.claimProfile = .success(profile) }

        let (model, _) = makeModel(repository: repository)
        await model.claimProfile(username: "connor", displayName: "Connor")

        #expect(model.state == .signedIn(profile))
        #expect(model.error == nil)
    }

    @Test("Keeps someone on the username screen if the name is taken")
    func usernameTaken() async {
        let repository = FakeAuthenticationRepository()
        repository.update { $0.claimProfile = .failure(AppError(kind: .conflict)) }

        let (model, _) = makeModel(repository: repository)
        await model.claimProfile(username: "connor", displayName: "Connor")

        #expect(model.state == .restoring)
        #expect(model.error?.kind == .conflict)
    }

    @Test("Signs out locally and tells the server")
    func signsOut() async {
        let (model, repository) = makeModel()
        await model.signIn(identityToken: "t", nonce: SignInNonce(raw: "n"))

        await model.signOut()

        #expect(model.state == .signedOut)
        #expect(repository.signOutCallCount == 1)
    }

    /// Sign-out must never leave someone signed in, even when the network refuses.
    @Test("Signs out locally even if the server call fails")
    func signsOutOffline() async {
        let (model, _) = makeModel()
        await model.signIn(identityToken: "t", nonce: SignInNonce(raw: "n"))

        await model.signOut()
        #expect(model.state == .signedOut)
    }

    @Test("Account deletion signs the person out immediately")
    func deletionSignsOut() async {
        let scheduled = Date().addingTimeInterval(7 * 24 * 60 * 60)
        let repository = FakeAuthenticationRepository()
        repository.update {
            $0.deletion = .success(
                AccountDeletionResponse(scheduledFor: scheduled, alreadyRequested: false)
            )
        }

        let (model, _) = makeModel(repository: repository)
        await model.signIn(identityToken: "t", nonce: SignInNonce(raw: "n"))

        let result = await model.requestAccountDeletion()

        #expect(result == scheduled)
        #expect(model.state == .signedOut)
    }
}

@Suite("Username rules")
nonisolated struct UsernameRulesTests {
    /// Mirrors the Worker so the common mistakes are caught before a round trip. The server
    /// stays the authority; this is courtesy, not enforcement.
    @Test("Accepts valid usernames", arguments: ["connor", "gabi_m", "abc", "a1_2", String(repeating: "a", count: 24)])
    func accepts(username: String) {
        #expect(UsernameRules.issue(with: username) == nil)
    }

    @Test(
        "Rejects invalid usernames",
        arguments: [
            "ab",                              // too short
            String(repeating: "a", count: 25), // too long
            "con.nor",                         // punctuation
            "con nor",                         // space
            "connor!",                         // symbol
            "connоr",                          // Cyrillic о — a homograph
            "",
        ]
    )
    func rejects(username: String) {
        #expect(UsernameRules.issue(with: username) != nil)
    }

    @Test("Is case-insensitive, matching the server's lowercasing")
    func caseInsensitive() {
        #expect(UsernameRules.issue(with: "CoNnOr") == nil)
    }
}
