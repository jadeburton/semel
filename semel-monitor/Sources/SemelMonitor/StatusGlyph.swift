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

    /// What the status item shows. No engine says more than a held error, whose card is
    /// still on screen to say it: the engine that would replace it is gone.
    public static func of(state: EngineSubscription.State, holdsErrors: Bool) -> StatusGlyph {
        switch state {
        case .noEngine:  return .noEngine
        case .connected: return holdsErrors ? .errors : .connected
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
        case .noEngine:  return "No engine"
        case .connected: return "Connected"
        case .errors:    return "Errors"
        }
    }
}
