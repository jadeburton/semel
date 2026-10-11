// GlyphImage.swift
// semel-monitor
//
// The status item's glyph drawn from `StatusGlyph`'s circles and lines: black as a template
// image the menu bar tints, or the system's red for errors, which a template would lose.
// A settling glyph is drawn twice, dimmed whole and then at full strength inside the
// sector its sweep has reached.

import AppKit
import SemelMonitor

enum GlyphImage {

    static func image(for glyph: StatusGlyph) -> NSImage {
        let side  = StatusGlyph.side
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            let colour: NSColor = glyph.isTemplate ? .black : .systemRed
            guard let sweep = glyph.sweep else {
                draw(glyph, in: colour)
                return true
            }
            draw(glyph, in: colour.withAlphaComponent(StatusGlyph.unreachedOpacity))
            let centre = NSPoint(x: bounds.midX, y: bounds.midY)
            let sector = NSBezierPath()
            sector.move(to: centre)
            // Out past the corners, so the sector covers the whole square it sweeps.
            sector.appendArc(withCenter: centre, radius: side, startAngle: sweep.start, endAngle: sweep.end, clockwise: true)
            sector.close()
            NSGraphicsContext.saveGraphicsState()
            sector.addClip()
            draw(glyph, in: colour)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate               = glyph.isTemplate
        image.accessibilityDescription = glyph.description
        return image
    }

    private static func draw(_ glyph: StatusGlyph, in colour: NSColor) {
        colour.setStroke()
        colour.setFill()
        for wire in StatusGlyph.wires {
            let segment = StatusGlyph.segment(of: wire)
            let line = NSBezierPath()
            line.move(to: point(segment.start))
            line.line(to: point(segment.end))
            line.lineWidth     = StatusGlyph.lineWidth
            line.lineCapStyle  = .round
            line.stroke()
        }
        for node in StatusGlyph.nodes {
            let radius = StatusGlyph.nodeRadius
            let bounds = NSRect(x: node.horizontal - radius, y: node.vertical - radius, width: radius * 2, height: radius * 2)
            guard glyph.fillsNodes else {
                // The outline inside the circle's bounds, so a hollow node is as large as a filled one.
                let outline = NSBezierPath(ovalIn: bounds.insetBy(dx: StatusGlyph.lineWidth / 2, dy: StatusGlyph.lineWidth / 2))
                outline.lineWidth = StatusGlyph.lineWidth
                outline.stroke()
                continue
            }
            NSBezierPath(ovalIn: bounds).fill()
        }
    }

    private static func point(_ glyphPoint: GlyphPoint) -> NSPoint {
        NSPoint(x: glyphPoint.horizontal, y: glyphPoint.vertical)
    }
}
