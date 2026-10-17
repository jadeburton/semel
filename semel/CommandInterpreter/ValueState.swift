// ValueState.swift
// semel
//
// The words the prompt says a product's or a file's state in. Inside the engine a port has
// a value or has none, for a reason (`NoValueReason`); a person reading the prompt is told
// what that means for them: a product is up to date, or it is pending — the graph will pass
// through to a value without anyone doing anything — or it is in error, which is theirs to
// act on. A source that was pushed and then taken away is neither, and is said plainly as
// removed.

import SemelNodeKit
import SemelProtocol

/// What the prompt calls a value's state: the one table of words, so `errors`, `ls`, the
/// summary line and the watcher say the same thing of the same state.
public enum ValueState: Equatable, Sendable, CaseIterable {
    /// It holds a value: what it is computed from is what the graph holds.
    case upToDate
    /// It holds none, in a state the graph passes through on its way to one: a node still
    /// to run, an input not produced yet, a port never processed.
    case pending
    /// It holds none because it failed, or because something it reads did.
    case inError
    /// A source that was pushed and then removed: not a failure, and nothing the graph
    /// will produce by itself.
    case removed

    public var word: String {
        switch self {
        case .upToDate: return "up to date"
        case .pending:  return "pending"
        case .inError:  return "in error"
        case .removed:  return "removed"
        }
    }

    /// The state a port's value is in.
    public init(_ value: NodeValue) {
        switch value {
        case .value:               self = .upToDate
        case .noValue(let reason): self = ValueState(reason: reason)
        }
    }

    /// Each reason by case, never by any text it carries.
    public init(reason: NoValueReason) {
        switch reason {
        case .pending, .initializing, .inputNotProduced: self = .pending
        case .inputInError, .error:                      self = .inError
        case .deleted:                                   self = .removed
        }
    }
}

// MARK: - ls

extension ValueState {

    /// The note `ls` prints beside a name, without its brackets, or nil for none. The
    /// listing's states are the reasons as the server groups them. A product holding its
    /// value is up to date; a source holding one, and a folder, are only there, and say
    /// nothing. One state takes two words: a name with no value in `input:` is a source the
    /// formula names and nobody pushed (B-118), where in `output:` it is a product still to
    /// come.
    static func listingNote(for status: EntryStatus, kind: EntryKind, in fileSystem: FileSystemKind) -> String? {
        switch status {
        case .none:         return fileSystem == .output && kind == .file ? ValueState.upToDate.word : nil
        case .unreferenced: return "unreferenced"
        case .pending:      return ValueState.pending.word
        case .notProduced:  return fileSystem == .input ? "not pushed" : ValueState.pending.word
        case .deleted:      return ValueState.removed.word
        case .failed:       return ValueState.inError.word
        }
    }
}
