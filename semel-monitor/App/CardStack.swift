// CardStack.swift
// semel-monitor
//
// The panels on screen, one per card the planner holds, stacked under the menu bar at the
// top right, newest on top. Which cards there are, and how many, is the planner's.

import AppKit
import SemelMonitor

final class CardStack {

    static let margin: CGFloat = 10
    static let gap:    CGFloat = 10

    var onClick: (Int) -> Void = { _ in }
    var onHover: (Int, Bool) -> Void = { _, _ in }

    private var panels: [Int: CardPanel] = [:]

    /// The screen the stack is on: the one holding the mouse when its first card came, kept
    /// until the stack empties, so a card never jumps to another display under a reader.
    private var screen: NSScreen?

    /// `cards` newest first, as the planner holds them.
    func show(_ cards: [Card]) {
        let shown = Set(cards.map(\.id))
        for (cardID, panel) in panels where !shown.contains(cardID) {
            panel.orderOut(nil)
            panels[cardID] = nil
        }
        guard !cards.isEmpty else {
            screen = nil
            return
        }
        let screen = self.screen ?? Self.screenWithMouse()
        self.screen = screen
        let visible = screen?.visibleFrame ?? .zero
        var top = visible.maxY - Self.margin
        for card in cards {
            let panel = panels[card.id] ?? makePanel(card)
            panel.show(card)
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - Self.margin, y: top - size.height))
            panel.orderFrontRegardless()
            top -= size.height + Self.gap
        }
    }

    private func makePanel(_ card: Card) -> CardPanel {
        let panel = CardPanel(card: card)
        panel.onClick = { [weak self] in self?.onClick(card.id) }
        panel.onHover = { [weak self] in self?.onHover(card.id, $0) }
        panels[card.id] = panel
        return panel
    }

    private static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}
