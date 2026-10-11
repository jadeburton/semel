// StatusGlyph.swift
// SemelMonitor
//
// The status item's glyph: Semel's own, a small graph of three nodes and two wires — two
// inputs wired into the node they build — drawn in code. Which state it shows is a
// function of the app's state, and its shape is a list of circles and lines, so both are
// tested here and the status item only strokes and fills them.
//
//     ●
//       ╲
//         ●       connected: filled, a template the menu bar tints
//       ╱         no engine: hollow
//     ●           errors held: filled, in the system's red
//                 settling: swept round like a clock hand by the settle's progress, the
//                 part not yet reached dimmed, and the pending count beside it

import SemelProtocol

/// A point in the glyph's square, in points, the origin at the bottom left as AppKit draws.
public struct GlyphPoint: Equatable, Sendable {
    public let horizontal: Double
    public let vertical: Double

    public init(horizontal: Double, vertical: Double) {
        self.horizontal = horizontal
        self.vertical   = vertical
    }
}

public enum StatusGlyph: Equatable, Sendable {
    /// No engine to subscribe to: the nodes drawn hollow, as a graph with no values.
    case noEngine
    /// Subscribed: the nodes filled.
    case connected
    /// An error card is held, on screen or swallowed by a pause: filled, in red.
    case errors
    /// A settle runs: the glyph filled as far round as `startedFraction` of its nodes have
    /// left the queue, the rest dimmed, and `pending` written beside it.
    case settling(pending: Int, startedFraction: Double)

    /// What the status item shows. No engine says more than a held error, whose card is
    /// still on screen to say it: the engine that would replace it is gone. A held error
    /// says more than a settle running: the error is something to act on, and the settle
    /// that may fix it will replace the card when it does.
    public static func of(state: EngineSubscription.State, holdsErrors: Bool,
                          settle: ProgressRecord? = nil) -> StatusGlyph {
        switch state {
        case .noEngine:
            return .noEngine
        case .connected:
            if holdsErrors {
                return .errors
            }
            guard let settle else {
                return .connected
            }
            return .settling(pending: settle.pending, startedFraction: settle.startedFraction)
        }
    }

    /// The side of the square the glyph is drawn in: the menu bar's glyph height.
    public static let side = 18.0

    /// The three nodes, the two inputs on the left and what they build on the right.
    public static let nodes = [GlyphPoint(horizontal: 4.5,  vertical: 13.5),
                               GlyphPoint(horizontal: 4.5,  vertical: 4.5),
                               GlyphPoint(horizontal: 13.5, vertical: 9)]

    public static let nodeRadius = 3.0

    /// The width of a wire and of a hollow node's outline.
    public static let lineWidth = 1.5

    /// How strongly the part of a settling glyph the sweep has not reached is drawn, as
    /// the mockup dims it.
    public static let unreachedOpacity = 0.45

    /// Each wire from one node to another, by index into `nodes`.
    public static let wires = [(source: 0, target: 2), (source: 1, target: 2)]

    /// A wire drawn between the nodes' rims, not their centres, so a hollow node stays
    /// empty inside.
    public static func segment(of wire: (source: Int, target: Int)) -> (start: GlyphPoint, end: GlyphPoint) {
        let start = nodes[wire.source]
        let end   = nodes[wire.target]
        let deltaHorizontal = end.horizontal - start.horizontal
        let deltaVertical   = end.vertical - start.vertical
        let length          = (deltaHorizontal * deltaHorizontal + deltaVertical * deltaVertical).squareRoot()
        let insetHorizontal = deltaHorizontal / length * nodeRadius
        let insetVertical   = deltaVertical / length * nodeRadius
        return (GlyphPoint(horizontal: start.horizontal + insetHorizontal, vertical: start.vertical + insetVertical),
                GlyphPoint(horizontal: end.horizontal - insetHorizontal, vertical: end.vertical - insetVertical))
    }

    /// The sector of the square a settling glyph draws at full strength, in degrees as
    /// AppKit measures them — anticlockwise from three o'clock — and drawn clockwise from
    /// `start` to `end`: from twelve o'clock round as far as the settle has gone, a clock
    /// hand's sweep. Nil for every other state, which is drawn whole.
    public var sweep: (start: Double, end: Double)? {
        guard case .settling(_, let fraction) = self else {
            return nil
        }
        let twelveOClock = 90.0
        return (twelveOClock, twelveOClock - 360 * min(1, max(0, fraction)))
    }

    /// What is written beside the glyph: the pending count while a settle runs.
    public var title: String? {
        guard case .settling(let pending, _) = self else {
            return nil
        }
        return "\(pending)"
    }

    /// Whether the nodes are filled, or outlined.
    public var fillsNodes: Bool {
        self != .noEngine
    }

    /// Whether the menu bar tints it as its own: every state but errors, whose red is the
    /// point.
    public var isTemplate: Bool {
        self != .errors
    }

    /// What VoiceOver and the tooltip call it.
    public var description: String {
        switch self {
        case .noEngine:                  return "No engine"
        case .connected:                 return "Connected"
        case .errors:                    return "Errors"
        case .settling(let pending, _):  return "Settling · \(pending) pending"
        }
    }
}
