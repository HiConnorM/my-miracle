import Foundation

/// A value that must not appear in logs, crash reports, analytics or error messages.
///
/// `Redacted` deliberately has no `CustomStringConvertible` output other than
/// `<redacted>`, so a value can only escape through an explicit, greppable `reveal()`
/// call. Use it for credentials, tokens, and any user-authored prayer or journal text
/// that has to be carried through infrastructure code.
///
/// Rules 4 and 7: keys never reach a log line; private prayer text never reaches
/// analytics.
nonisolated struct Redacted<Value>: Sendable where Value: Sendable {
    private let value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// Unwraps the underlying value.
    ///
    /// Every call site is a deliberate decision to handle sensitive data. Search for
    /// `.reveal()` when auditing where secrets flow.
    func reveal() -> Value {
        value
    }

    /// Applies a transform without widening exposure.
    func map<Other: Sendable>(_ transform: (Value) -> Other) -> Redacted<Other> {
        Redacted<Other>(transform(value))
    }
}

nonisolated extension Redacted: CustomStringConvertible {
    var description: String { "<redacted>" }
}

nonisolated extension Redacted: CustomDebugStringConvertible {
    var debugDescription: String { "<redacted>" }
}

nonisolated extension Redacted: Equatable where Value: Equatable {
    static func == (lhs: Redacted<Value>, rhs: Redacted<Value>) -> Bool {
        lhs.value == rhs.value
    }
}

nonisolated extension Redacted where Value == String {
    var isEmpty: Bool { value.isEmpty }
}
