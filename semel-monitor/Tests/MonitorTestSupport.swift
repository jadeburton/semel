//
//  MonitorTestSupport.swift
//  SemelMonitorTests
//
//  A clock that moves only when a test says, and the events and records a test feeds the
//  planner, written as the server sends them.
//

import Foundation
import SemelNodeKit
import SemelProtocol
@testable import SemelMonitor

final class ManualClock: Clock {
    private(set) var now: Duration = .zero

    func advance(by duration: Duration) {
        now += duration
    }
}

enum Events {

    /// `settled` with `computed` and `fromCache` making up `scheduled`.
    static func settled(computed: Int = 1, fromCache: Int = 0, errors: Int = 0) -> DaemonEvent {
        .settled(scheduled: computed + fromCache, computed: computed, fromCache: fromCache, errors: errors)
    }

    static func artifacts(appeared: [String] = [], changed: [String] = [], disappeared: [String] = [],
                          treeFolders: [String: String] = [:]) -> DaemonEvent {
        .artifacts(appeared: appeared, changed: changed, disappeared: disappeared, treeFolders: treeFolders)
    }

    /// A `progress` listing nothing running: what a settle's last record says, and what
    /// shows no running card.
    static func progress() -> DaemonEvent {
        .progress(record: ProgressRecord(scheduled: 1, computed: 0, fromCache: 0, pending: 1, running: []))
    }

    /// A `progress` with `running` compiles named `src/<name>.c` running.
    static func progress(scheduled: Int = 10, computed: Int = 0, fromCache: Int = 0, pending: Int = 5,
                         running names: [String]) -> DaemonEvent {
        .progress(record: record(scheduled: scheduled, computed: computed, fromCache: fromCache, pending: pending,
                                 running: names))
    }

    static func record(scheduled: Int = 10, computed: Int = 0, fromCache: Int = 0, pending: Int = 5,
                       running names: [String]) -> ProgressRecord {
        ProgressRecord(scheduled: scheduled, computed: computed, fromCache: fromCache, pending: pending,
                       running: names.map(compile(of:)))
    }

    /// The compile of `src/<name>.c`, as the engine describes it: by its source, with an
    /// identity of its own.
    static func compile(of name: String) -> ActiveNode {
        ActiveNode(type: "ClangCompiler", name: "input:/src/\(name).c.p", subject: .source(path: "input:/src/\(name).c"),
                   identity: "identity-of-\(name)")
    }

    /// A compile error stopping `products`.
    static func compileError(_ line: String = "input:/c/src/hello.c:3:5: error: use of undeclared identifier 'x'",
                             products: [StoppedProduct]) -> ErrorRecord {
        ErrorRecord(document: .tool(text: line, tool: "clang", status: 1, subject: .source(path: "input:/c/src/hello.c")),
                    products: products,
                    facts:    ErrorFacts(nodeType: "ClangCompiler", nodeIDs: [7], ports: ["output"], carrierCount: 0))
    }

    static func products(_ paths: String...) -> [StoppedProduct] {
        paths.map { StoppedProduct(path: $0) }
    }
}

extension NotificationPlanner {

    /// Feeds one settle's events in the server's order and returns every change.
    @discardableResult
    func settle(_ events: DaemonEvent...) -> [CardChange] {
        events.flatMap { receive($0) }
    }
}

extension CardChange {
    /// The card shown, or nil for any other change.
    var shownCard: Card? {
        guard case .shown(let card) = self else {
            return nil
        }
        return card
    }
}
