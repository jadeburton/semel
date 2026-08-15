//
//  ProductPresence.swift
//  BuildSystemCore
//
//  Which products exist, and what changed since the last pass.
//
//  A product's OutputFile node is deleted and recreated whenever anything upstream of it
//  changes, because a node's identity includes its static wiring — so watching node
//  lifecycles reports a file as deleted and recreated when nothing about the file moved.
//  ProjectBuilder holds a wire from every product's status and is keyed by *path*, which
//  is stable across that churn, so it is the honest place to decide what exists.
//
//  Kept separate from ProjectBuilder deliberately: the decision is a pure function of the
//  previous state and the statuses seen this pass, so it can be tested without a graph.
//

import Foundation
import SemelNodeKit

/// Something that happened to a product between two passes.
///
/// Deliberately not "changed": a *content* change is invisible here, because the value on
/// the wire is the status string, which is the same hash whether or not the product was
/// rebuilt. OutputFile reports that itself.
enum ProductEvent: Equatable {
    case created(path: String)
    case deleted(path: String)
}

enum ProductPresence {

    /// Decides what exists now, and what that means happened.
    ///
    /// `pending` is treated as *no news* rather than as absence. A product goes
    /// value → pending → value on every rebuild, so counting pending as gone would report
    /// a delete and a create each time — which is the flapping this exists to remove.
    static func reconcile(existingBefore: Set<String>,
                          statuses: [String: NodeValue]) -> (events: [ProductEvent], existingNow: Set<String>) {

        var existingNow: Set<String> = []
        var events: [ProductEvent] = []

        // Sorted: these become user-visible output, and Dictionary and Set iteration order
        // both vary between processes.
        for path in existingBefore.union(statuses.keys).sorted() {
            let existedBefore = existingBefore.contains(path)
            let existsNow: Bool

            switch statuses[path] {
            case .value:
                existsNow = true
            case .noValue(.pending):
                existsNow = existedBefore          // no news
            case .noValue(.error):
                existsNow = false
            case nil:
                // No wire at all: the product left the formula. Note this arrives a pass
                // late, because a dropped expectation is unwired only after process()
                // returns, so its old value is still on the port during that pass.
                existsNow = false
            }

            if existsNow {
                existingNow.insert(path)
            }
            if existsNow != existedBefore {
                events.append(existsNow ? .created(path: path) : .deleted(path: path))
            }
        }

        return (events, existingNow)
    }

    // MARK: - Carrying the set between passes

    /// Stored on an output port rather than in a property: it is data, not identity, and a
    /// property would land in the node's searchKey. Being in the database also means the
    /// set survives a restart, so the first pass after launch reports only real changes.
    static func encode(_ paths: Set<String>) throws -> String {
        // Sorted so the stored value is stable for an unchanged set.
        let data = try JSONEncoder().encode(paths.sorted())
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ nodeValue: NodeValue) -> Set<String> {
        guard case .value(let hash) = nodeValue,
              let json = try? hash.resolveAsString(),
              let paths = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
        else {
            // No previous value — first pass, or the port has never been written. Treating
            // that as "nothing existed" makes the first pass report every live product as
            // created, which is the correct reading of "we did not know about it before".
            return []
        }
        return Set(paths)
    }
}
