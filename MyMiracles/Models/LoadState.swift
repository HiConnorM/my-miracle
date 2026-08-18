import Foundation

/// The states every screen must handle.
///
/// Rule 19 requires loading, empty, error and offline behavior for every feature. Making
/// that a single exhaustive enum means a `switch` in the view forces each one to be
/// answered rather than forgotten.
nonisolated enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    /// Loaded, but there is deliberately nothing to show — "you're caught up", an empty
    /// journal, no prayers today.
    case empty
    case loaded(Value)
    case failed(AppError)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var error: AppError? {
        if case .failed(let error) = self { return error }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    func map<Other: Sendable>(_ transform: (Value) -> Other) -> LoadState<Other> {
        switch self {
        case .idle: .idle
        case .loading: .loading
        case .empty: .empty
        case .loaded(let value): .loaded(transform(value))
        case .failed(let error): .failed(error)
        }
    }
}

nonisolated extension LoadState where Value: Collection {
    /// Collapses an empty collection into ``empty`` so screens cannot accidentally render
    /// a blank list instead of a designed empty state.
    static func resolved(_ collection: Value) -> LoadState<Value> {
        collection.isEmpty ? .empty : .loaded(collection)
    }
}

nonisolated extension LoadState: Equatable where Value: Equatable {
    static func == (lhs: LoadState<Value>, rhs: LoadState<Value>) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.empty, .empty): true
        case (.loaded(let left), .loaded(let right)): left == right
        case (.failed(let left), .failed(let right)): left == right
        default: false
        }
    }
}
