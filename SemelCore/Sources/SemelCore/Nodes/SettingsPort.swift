// SettingsPort.swift
// SemelCore
//
// How the settings nodes read an input port: one wire, its text parsed as configuration.

import SemelNodeKit

extension ProcessInput {

    /// The settings on `port`'s one wire, or nothing when the port has no wire or the wire
    /// carries no value.
    ///
    /// One wire, and two is an error naming them (B-120). `ConfigMerger` is the one place
    /// two sets of settings meet, with `base` and `override` saying which wins; a port that
    /// folded several wires together in key order would be a second merge beside it whose
    /// precedence nobody stated — the order of two names nobody chose for their order.
    ///
    /// A wire carrying no value contributes nothing rather than failing the node. What
    /// arrives is often not an absence: a `StaticFile` nobody has pushed publishes
    /// `noValue(.initializing)`, and the node still runs on that, because
    /// `allInputsAreSatisfied` waits on `pending` and on nothing else. Which node carries
    /// the error is all this decides: the tool that needs a setting is what can say which
    /// one is missing, and a file nobody pushed is named by the report from the state its
    /// own port holds.
    func settings(onPort port: String) throws -> [String: String] {
        guard let wire = try onlyWire(onOptionalPort: port),
              let hash = try? wire.value.expectValue() else {
            return [:]
        }
        return [String: String](plainText: try hash.resolveAsString())
    }
}
