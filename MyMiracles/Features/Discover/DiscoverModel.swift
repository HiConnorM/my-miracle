import Foundation
import Observation

/// Finding people.
///
/// The whole of discovery is a search box. There is no ranked list of accounts to follow,
/// no "people you may know", and nothing trending — someone has to be looking for a person
/// to find one, which is the difference between a directory and a growth mechanic
/// (docs/product-spec.md).
@MainActor
@Observable
final class DiscoverModel {
    private(set) var state: LoadState<[PersonSummary]> = .idle
    private(set) var error: AppError?

    var query = ""

    private var searchToken = UUID()
    private let repository: any SocialRepository

    init(repository: any SocialRepository) {
        self.repository = repository
    }

    var hasQuery: Bool { trimmed.count >= 2 }

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the search, discarding anything that arrives out of order.
    ///
    /// Typing "gab" then "gabi" must not end with results for "gab" on screen — a stale
    /// answer showing the wrong people is worse than showing none.
    func search() async {
        guard hasQuery else {
            state = .idle
            return
        }

        let token = UUID()
        searchToken = token
        state = .loading

        do {
            let people = try await repository.searchPeople(query: trimmed)
            guard token == searchToken else { return }
            state = .resolved(people)
            error = nil
        } catch {
            guard token == searchToken else { return }
            state = .failed(error)
        }
    }

    func clear() {
        query = ""
        searchToken = UUID()
        state = .idle
    }

    /// Follows or unfollows from the results, optimistically.
    func toggleFollow(_ person: PersonSummary) async {
        guard var people = state.value,
              let index = people.firstIndex(where: { $0.username == person.username })
        else { return }

        let wasFollowing = people[index].isFollowing
        let restore = people
        people[index].isFollowing.toggle()
        state = .loaded(people)

        do {
            if wasFollowing {
                try await repository.unfollow(username: person.username)
            } else {
                try await repository.follow(username: person.username)
            }
        } catch {
            state = .loaded(restore)
            self.error = error
        }
    }

    func dismissError() { error = nil }
}
