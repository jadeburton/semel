// LiveWindowModel.swift
// SemelMonitor
//
// What the live window behind *Show window* shows, as a value: the nodes running now with
// how long each has run, a bar for pending against scheduled, the settle's counts, and the
// last settle's products and errors through the products window's own model. All of it
// from the events the server sends to every subscriber; the window asks the engine for
// nothing. How long a node has run is the app's to say — the engine is a time-free zone —
// so it is measured on the app's clock from the `progress` record that first listed it.
//
//     semel · settling
//     scheduled 88 · computed 31 · from cache 9 · pending 48 · running 12
//     ▓▓▓▓▓▓▓▓▓░░░░░░░░░░
//     SwiftCompiler   Models                  2.1 s
//     ClangCompiler   Sources/parser.c        0.6 s

import SemelProtocol

/// One node running now, and for how long the app has seen it run.
public struct RunningNodeRow: Equatable, Sendable {
    public let type: String
    /// What it is computed for, as `RunningNodeNames` writes it.
    public let name: String
    public let elapsed: Duration
}

/// What `settled` counted for the last settle that ended.
public struct SettledCounts: Equatable, Sendable {
    public let scheduled: Int
    public let computed:  Int
    public let fromCache: Int
    public let errors:    Int
}

public struct LiveWindowModel {

    public enum Phase: Equatable, Sendable {
        case noEngine
        case idle
        case settling
    }

    public private(set) var phase = Phase.noEngine

    /// The settle in progress, from its latest `progress`; nil between settles.
    public private(set) var progress: ProgressRecord?

    /// The last settle that ended, as `settled` counted it; nil before one has.
    public private(set) var lastSettled: SettledCounts?

    /// The last settle's products and errors, in the products window's model; nil before a
    /// settle has ended.
    public private(set) var lastSettle: ProductsWindowModel?

    /// The card the last settle's products are marked from: what the settle moved, or its
    /// errors when it moved nothing; nil when it did neither.
    public private(set) var lastSettleCard: Card?

    /// When each running node was first listed, in the record's order. Matched by the whole
    /// description — type, subject, name and identity — the first unmatched of each, so two
    /// nodes of one description each keep their own start.
    private var started: [(node: ActiveNode, at: Duration)] = []

    /// The events of a settle not yet ended: its errors come before its `settled`, and its
    /// products after.
    private var settleErrors: [ErrorRecord] = []
    private var reading = Reading.between

    private enum Reading {
        /// No settle is being read: the next event begins one.
        case between
        /// A settle's `progress` or `errors` have come.
        case running
        /// Its `settled` has come; an `artifacts` may follow.
        case settled
    }

    public init() {}

    // MARK: - Events

    /// The window's state after `event`, which arrived at `now` on the app's clock.
    public mutating func receive(_ event: DaemonEvent, at now: Duration) {
        switch event {
        case .progress(let record):
            beginSettleIfNeeded()
            phase    = .settling
            progress = record
            started  = Self.match(record.running, against: started, at: now)
        case .errors(let records):
            beginSettleIfNeeded()
            settleErrors += records
        case .settled(let scheduled, let computed, let fromCache, let errors):
            lastSettled = SettledCounts(scheduled: scheduled, computed: computed, fromCache: fromCache, errors: errors)
            endSettle()
            publish(appeared: [], changed: [], treeFolders: [:])
            reading = .settled
        case .artifacts(let appeared, let changed, let disappeared, let treeFolders):
            // A removal that scheduled nothing sends its products with no `settled`: a
            // settle of its own.
            if reading == .between {
                settleErrors = []
            }
            endSettle()
            publish(appeared: appeared, changed: changed, disappeared: disappeared, treeFolders: treeFolders)
            reading = .between
        case .notice:
            break
        }
    }

    /// The subscription is up: the engine is idle until its next `progress` says otherwise.
    public mutating func connected() {
        if phase == .noEngine {
            phase = .idle
        }
    }

    /// The connection is gone, and the settle being read with it.
    public mutating func engineLost() {
        phase        = .noEngine
        progress     = nil
        started      = []
        settleErrors = []
        reading      = .between
    }

    // MARK: - What the window draws

    /// The nodes running now, in the order they started, each with how long it has run at
    /// `now`.
    public func runningRows(at now: Duration) -> [RunningNodeRow] {
        let subjects = RunningNodeNames.subjects(of: started.map(\.node))
        return zip(started, subjects).map { entry, subject in
            RunningNodeRow(type: entry.node.type, name: subject, elapsed: now - entry.at)
        }
    }

    /// How far the bar is drawn: pending against scheduled while a settle runs, full once
    /// one has ended, empty before any has.
    public var barFraction: Double {
        if let progress {
            return progress.startedFraction
        }
        return lastSettled == nil ? 0 : 1
    }

    /// `scheduled 88 · computed 31 · from cache 9 · pending 48 · running 12` while a settle
    /// runs; the last one's `settled` counts after it; nil before either.
    public var countsLine: String? {
        if let progress {
            return "scheduled \(progress.scheduled) · computed \(progress.computed) · from cache \(progress.fromCache)"
                + " · pending \(progress.pending) · running \(progress.running.count)"
        }
        return lastSettled.map {
            "scheduled \($0.scheduled) · computed \($0.computed) · from cache \($0.fromCache) · errors \($0.errors)"
        }
    }

    /// `semel · settling`, `semel · idle`, `semel · no engine`.
    public var title: String {
        switch phase {
        case .noEngine: return "semel · no engine"
        case .idle:     return "semel · idle"
        case .settling: return "semel · settling"
        }
    }

    /// `last settle: 2 products changed`, its card's headline, or what it came to when it
    /// moved nothing; nil before a settle has ended.
    public var lastSettleLine: String? {
        guard lastSettle != nil else {
            return nil
        }
        return "last settle: " + (lastSettleCard.map(CardText.headline(of:)) ?? "no product moved")
    }

    // MARK: - The settle

    private mutating func beginSettleIfNeeded() {
        guard reading != .running else {
            return
        }
        settleErrors = []
        reading      = .running
    }

    private mutating func endSettle() {
        if phase == .settling {
            phase = .idle
        }
        progress = nil
        started  = []
    }

    /// The settle's products and errors into the products window's model, marked as a card
    /// for the settle would mark them; what was selected stays selected while it is there.
    private mutating func publish(appeared: [String], changed: [String], disappeared: [String] = [],
                                  treeFolders: [String: String]) {
        let snapshot = ProductsSnapshot.ofSettle(appeared: appeared, changed: changed, treeFolders: treeFolders,
                                                 errors: settleErrors)
        let moved = !(appeared.isEmpty && changed.isEmpty && disappeared.isEmpty)
        if moved {
            lastSettleCard = Card(id: 0, content: .result(changed: changed, appeared: appeared, disappeared: disappeared,
                                                          counts: nil, treeFolders: treeFolders))
        } else {
            lastSettleCard = settleErrors.isEmpty ? nil : Card(id: 0, content: .errors(records: settleErrors))
        }
        if var model = lastSettle {
            model.refresh(with: snapshot, card: lastSettleCard)
            lastSettle = model
        } else {
            lastSettle = ProductsWindowModel(snapshot: snapshot, card: lastSettleCard)
        }
    }

    /// Each node of `running` with the moment it was first listed: carried over from
    /// `previous` for a node still running, `now` for one this record lists first.
    static func match(_ running: [ActiveNode], against previous: [(node: ActiveNode, at: Duration)],
                      at now: Duration) -> [(node: ActiveNode, at: Duration)] {
        var unmatched = previous
        return running.map { node in
            guard let index = unmatched.firstIndex(where: { $0.node == node }) else {
                return (node, now)
            }
            return unmatched.remove(at: index)
        }
    }
}

/// How long a node has run, as the live window writes it: tenths of a second under a
/// minute, then minutes and seconds — the same on every machine whatever its locale.
public enum ElapsedText {
    public static func text(_ elapsed: Duration) -> String {
        let seconds = max(0, elapsed.timeInterval)
        let secondsPerMinute = 60.0
        guard seconds >= secondsPerMinute else {
            let tenths = Int((seconds * 10).rounded(.down))
            return "\(tenths / 10).\(tenths % 10) s"
        }
        let whole = Int(seconds.rounded(.down))
        return "\(whole / 60) min \(whole % 60) s"
    }
}
