import Foundation
import Testing
@testable import MyMiracles

@Suite("Load state")
nonisolated struct LoadStateTests {
    /// Rule 19: an empty result must reach a designed empty state, not a blank list.
    @Test("An empty collection resolves to the empty state")
    func emptyCollectionResolvesToEmpty() {
        #expect(LoadState.resolved([Int]()) == .empty)
        #expect(LoadState.resolved([1, 2]) == .loaded([1, 2]))
    }

    @Test("Accessors expose only the matching case")
    func accessors() {
        let failure = LoadState<[Int]>.failed(AppError(kind: .offline))

        #expect(failure.value == nil)
        #expect(failure.error?.kind == .offline)
        #expect(!failure.isLoading)
        #expect(LoadState<[Int]>.loading.isLoading)
        #expect(LoadState.loaded([1]).value == [1])
    }

    @Test("Mapping preserves the case")
    func mapping() {
        #expect(LoadState.loaded([1, 2]).map(\.count) == .loaded(2))
        #expect(LoadState<[Int]>.empty.map(\.count) == .empty)
        #expect(LoadState<[Int]>.loading.map(\.count) == .loading)
        #expect(LoadState<[Int]>.idle.map(\.count) == .idle)
    }
}

@Suite("App error")
nonisolated struct AppErrorTests {
    @Test("Offline is presented as pending work, not failure")
    func offlineIsPending() {
        let offline = AppError(kind: .offline)

        #expect(offline.isPending)
        #expect(offline.isRetryable)
        // Nothing is lost — this promise is load-bearing for the outbox in Phase 13.
        #expect(offline.message.contains("Nothing is lost"))
    }

    @Test("Permission denied is not retryable")
    func permissionDeniedIsTerminal() {
        // An RLS policy saying no is a correct outcome, not something to retry around.
        #expect(!AppError(kind: .permissionDenied).isRetryable)
        #expect(!AppError(kind: .notAuthenticated).isRetryable)
        #expect(!AppError(kind: .configuration).isRetryable)
    }

    @Test("Every kind has user-facing copy free of technical detail", arguments: AppError.Kind.allCases)
    func copyIsHuman(kind: AppError.Kind) {
        let error = AppError(kind: kind, diagnostic: "PostgrestError code=42501 body=secret")

        #expect(!error.title.isEmpty)
        #expect(!error.message.isEmpty)
        #expect(!error.message.contains("42501"))
        #expect(!error.message.contains("secret"))
        #expect(!error.message.contains("Postgrest"))
    }

    @Test("URL errors map to offline and timeout")
    func urlErrorMapping() {
        let notConnected = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        #expect(AppError.unexpected(notConnected).kind == .offline)
        #expect(AppError.unexpected(timedOut).kind == .timedOut)
        #expect(AppError.unexpected(CancellationError()).kind == .timedOut)
    }

    @Test("An existing app error passes through unchanged")
    func passthrough() {
        #expect(AppError.unexpected(AppError(kind: .conflict)).kind == .conflict)
    }

    @Test("A configuration failure becomes a configuration error")
    func configurationMapping() {
        let error = AppError(configurationError: .embeddedCredential("MMSessionSecret"))
        #expect(error.kind == .configuration)
        #expect(error.diagnostic?.description == "<redacted>")
    }
}
