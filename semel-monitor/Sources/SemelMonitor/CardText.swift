// CardText.swift
// SemelMonitor
//
// The words on a card. Every one is a word the engine's events carry — appeared, changed,
// disappeared, without a value, computed, from cache — and every product is named as the
// error report names it (B-145), through the report's own `ProductNames`.
//
//     3 products changed, 1 appeared
//     App, libModels.a, libConversations.a and 1 more
//     3 computed · 9 from cache
//
//     2 products without a value
//     Packages/Models/Sources/Models/Account.swift:201:28: error: cannot convert value …
//     libConversations.a, libExplore.a
//     1 error · 2 products without a value

import SemelCLI
import SemelProtocol

public enum CardText {

    /// How many products a card names before it counts the rest, as a report heading does.
    public static let productsNamed = 3

    /// The headline, then what is under it: for errors the first cause's line one; the
    /// names; the counts; and, on the bottom card of a full stack, how many were folded.
    public static func lines(for card: Card) -> [String] {
        [headline(of: card)]
            + [diagnosticLine(of: card), namesLine(of: card), countsLine(of: card), earlierLine(of: card)].compactMap { $0 }
    }

    /// `3 products changed, 1 appeared`; `1 product disappeared`; `2 products without a
    /// value`, or the error count for errors no product needs.
    public static func headline(of card: Card) -> String {
        switch card.content {
        case .result(let changed, let appeared, let disappeared, _):
            let parts = resultParts(changed: changed.count, appeared: appeared.count, disappeared: disappeared.count)
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
            return "\(products) \(products == 1 ? "product" : "products") without a value"
        }
    }

    /// The headline without its noun, for the status item's menu: `last settle: 3
    /// changed, 1 appeared`.
    public static func summary(of card: Card) -> String {
        switch card.content {
        case .result(let changed, let appeared, let disappeared, _):
            return resultParts(changed: changed.count, appeared: appeared.count, disappeared: disappeared.count)
                .map { "\($0.total) \($0.verb)" }
                .joined(separator: ", ")
        case .errors:
            return headline(of: card)
        }
    }

    /// The lines `--print` writes for one change: a card as its headline after `card:`
    /// and the rest indented under it; a card that goes, by its headline. An update to a
    /// card's `earlier` count writes nothing: the fold that moved it was written.
    public static func printed(_ change: CardChange) -> [String] {
        switch change {
        case .shown(let card):
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
    private static func resultParts(changed: Int, appeared: Int, disappeared: Int) -> [(total: Int, verb: String)] {
        [(changed, "changed"), (appeared, "appeared"), (disappeared, "disappeared")].filter { $0.total > 0 }
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
    /// the path under `output:` only for two of one name, a tree by its folder.
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

    /// `3 computed · 9 from cache` for a result; for errors, the report's own summary line.
    public static func countsLine(of card: Card) -> String? {
        switch card.content {
        case .result(_, _, _, let counts):
            return counts.map { "\($0.computed) computed · \($0.fromCache) from cache" }
        case .errors(let records):
            return ErrorReportRenderer.summaryLine(for: records)
        }
    }
}
