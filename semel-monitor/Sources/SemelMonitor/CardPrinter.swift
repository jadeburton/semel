// CardPrinter.swift
// SemelMonitor
//
// What `--print` writes for the planner's changes: `CardText.printed`, with a running
// card's progress held to a rate a reader can follow. A panel redraws on every `progress`;
// a line per `progress` on a build of a thousand nodes is a flood that hides the cards.

import SemelProtocol

public final class CardPrinter {

    /// The least time between two `running:` lines of one settle.
    public static let runningLineInterval = Duration.seconds(1)

    private let clock: any Clock

    /// The running nodes the last `running:` line was written for, and when; nil when no
    /// running card is on screen.
    private var printedRunning: [ActiveNode]?
    private var printedAt: Duration = .zero

    public init(clock: any Clock) {
        self.clock = clock
    }

    /// The running card's first line is always written. After it, a line is written when
    /// the running set has changed since the last one *and* a second has passed since it:
    /// one line per change of the running set or per second, whichever is rarer. Each such
    /// line is followed by the running nodes, a line each, as the card lists them.
    public func lines(for changes: [CardChange]) -> [String] {
        changes.flatMap(lines(for:))
    }

    private func lines(for change: CardChange) -> [String] {
        switch change {
        case .shown(let card) where card.kind == .running:
            guard case .running(let record) = card.content else {
                return []
            }
            printedRunning = record.running
            printedAt      = clock.now
            return CardText.printed(change)
        case .progressed(let card):
            guard case .running(let record) = card.content,
                  record.running != printedRunning,
                  clock.now - printedAt >= Self.runningLineInterval else {
                return []
            }
            printedRunning = record.running
            printedAt      = clock.now
            return CardText.printed(change)
        case .resolved:
            printedRunning = nil
            return CardText.printed(change)
        case .dismissed(let card) where card.kind == .running:
            printedRunning = nil
            return CardText.printed(change)
        case .shown, .dismissed, .folded, .updated:
            return CardText.printed(change)
        }
    }
}
