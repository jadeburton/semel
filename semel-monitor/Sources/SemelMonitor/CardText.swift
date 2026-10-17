// CardText.swift
// SemelMonitor
//
// The words on a card. Every one is a word the engine's events carry — appeared, changed,
// disappeared, in error, computed, from cache, running, pending — and every product
// is named as the error report names it (B-145), through the report's own `ProductNames`.
//
//     3 products changed, 1 appeared
//     App, libModels.a, libConversations.a and 1 more
//     3 computed · 9 from cache
//
//     2 products in error
//     Packages/Models/Sources/Models/Account.swift:201:28: error: cannot convert value …
//     libConversations.a, libExplore.a
//     1 error · 2 products in error
//
//     Building · 3 running · 48 ahead
//     SwiftCompiler  App
//     SwiftCompiler  Models
//     ClangCompiler  Sources/parser.c
//     31 computed · 9 from cache · 48 pending

import SemelCLI
import SemelProtocol

public enum CardText {

    /// How many products a card names before it counts the rest, as a report heading does.
    public static let productsNamed = 3

    /// How many running nodes a running card lists, a line each, before it counts the rest:
    /// as many as a machine of a common size runs at once.
    public static let runningNodesListed = 8

    /// The headline, then what is under it: for errors the first cause's line one; the
    /// names, or a running card's nodes a line each; the counts; and, on the bottom card of
    /// a full stack, how many were folded.
    public static func lines(for card: Card) -> [String] {
        [headline(of: card)]
            + [diagnosticLine(of: card), namesLine(of: card)].compactMap { $0 }
            + runningLines(of: card)
            + [countsLine(of: card), earlierLine(of: card)].compactMap { $0 }
    }

    /// `3 products changed, 1 appeared`; `1 product disappeared`; `2 products in error`,
    /// or the error count for errors no product needs; `Building · 12 running · 48
    /// ahead` while a settle runs.
    public static func headline(of card: Card) -> String {
        switch card.content {
        case .running(let record):
            return "Building · \(record.running.count) running · \(record.pending) ahead"
        case .result:
            let parts = resultParts(of: card.movedProducts)
            guard let first = parts.first else {
                return "no product moved"
            }
            let noun = first.total == 1 ? "product" : "products"
            return (["\(first.total) \(noun) \(first.verb)"] + parts.dropFirst().map { "\($0.total) \($0.verb)" })
                .joined(separator: ", ")
        case .errors(let records):
            let products = ErrorReportRenderer.productsWithoutValue(records).count
            guard products > 0 else {
                let errors = ErrorReportRenderer.errorCount(of: records)
                return "\(errors) \(errors == 1 ? "error" : "errors")"
            }
            return "\(products) \(products == 1 ? "product" : "products") \(ValueState.inError.word)"
        }
    }

    /// The headline without its noun, for the status item's menu: `last settle: 3
    /// changed, 1 appeared`.
    public static func summary(of card: Card) -> String {
        switch card.content {
        case .result:
            return resultParts(of: card.movedProducts)
                .map { "\($0.total) \($0.verb)" }
                .joined(separator: ", ")
        case .running, .errors:
            return headline(of: card)
        }
    }

    /// The lines `--print` writes for one change: a card as its headline after `card:`
    /// and the rest indented under it; a running card as `running:` and its headline, with
    /// its running nodes indented under it; a card that goes, by its headline. An update to
    /// a card's `earlier` count writes nothing: the fold that moved it was written. How
    /// often a running card's progress is written is `CardPrinter`'s to decide.
    public static func printed(_ change: CardChange) -> [String] {
        switch change {
        case .shown(let card) where card.kind == .running, .progressed(let card):
            return ["running: \(headline(of: card))"] + runningLines(of: card).map { "  \($0)" }
        case .shown(let card), .resolved(let card):
            let lines = lines(for: card)
            return ["card: \(lines[0])"] + lines.dropFirst().map { "  \($0)" }
        case .dismissed(let card):
            return ["dismissed: \(headline(of: card))"]
        case .folded(let card):
            return ["folded: \(headline(of: card))"]
        case .updated:
            return []
        }
    }

    // MARK: - The parts

    /// Changed first, as the common case is a save that changed what was there.
    private static func resultParts(of moved: MovedProducts) -> [(total: Int, verb: String)] {
        [(moved.changed.count, "changed"), (moved.appeared.count, "appeared"), (moved.disappeared.count, "disappeared")]
            .filter { $0.total > 0 }
    }

    /// For errors, the first cause's line one as the report draws it, so a compile error
    /// reads as the compiler wrote it.
    public static func diagnosticLine(of card: Card) -> String? {
        guard case .errors(let records) = card.content else {
            return nil
        }
        return ErrorReportRenderer.firstLine(of: records)
    }

    /// `and 2 earlier`, on the bottom card of a full stack.
    public static func earlierLine(of card: Card) -> String? {
        card.earlier > 0 ? "and \(card.earlier) earlier" : nil
    }

    /// Three names and `and N more`, named as the report names products: by file name,
    /// the path under `output:` only for two of one name, a tree by its folder. Nil for a
    /// running card, which lists nodes rather than products (`runningLines`).
    public static func namesLine(of card: Card) -> String? {
        let products = card.products
        guard !products.isEmpty else {
            return nil
        }
        let names = ProductNames(products: products)
        let shown = products.prefix(productsNamed).map { ProductNames.headingName(names.name(of: $0)) }
        let rest  = products.count - shown.count
        return shown.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }

    /// `3 computed · 9 from cache` for a result; for errors, the report's own summary line;
    /// `31 computed · 9 from cache · 48 pending` while a settle runs.
    public static func countsLine(of card: Card) -> String? {
        switch card.content {
        case .running(let record):
            return "\(record.computed) computed · \(record.fromCache) from cache · \(record.pending) pending"
        case .result(_, _, _, let counts, _):
            return counts.map { "\($0.computed) computed · \($0.fromCache) from cache" }
        case .errors(let records):
            return ErrorReportRenderer.summaryLine(for: records)
        }
    }

    /// How far a running card's bar is drawn, nil for any other card.
    public static func barFraction(of card: Card) -> Double? {
        guard case .running(let record) = card.content else {
            return nil
        }
        return record.startedFraction
    }

    /// A running card's nodes, a line each — `SwiftCompiler  Models` — in the order the
    /// record lists them, which is the order they started: a node that keeps running keeps
    /// its place above the ones that started after it, and a node that starts is a new
    /// line at the bottom. Up to `runningNodesListed`, then `and N more`; none for any
    /// other card.
    public static func runningLines(of card: Card) -> [String] {
        guard case .running(let record) = card.content else {
            return []
        }
        let lines = RunningNodeNames.lines(of: record.running)
        let shown = lines.prefix(runningNodesListed)
        let rest  = lines.count - shown.count
        return Array(shown) + (rest > 0 ? ["and \(rest) more"] : [])
    }
}

extension ProgressRecord {

    /// Pending against scheduled: the share of the nodes the settle has scheduled that are
    /// no longer waiting to start. What the running card's bar, the live window's bar and
    /// the status item's ring draw. Zero for a record that has scheduled nothing.
    public var startedFraction: Double {
        guard scheduled > 0 else {
            return 0
        }
        return min(1, max(0, Double(scheduled - pending) / Double(scheduled)))
    }
}
