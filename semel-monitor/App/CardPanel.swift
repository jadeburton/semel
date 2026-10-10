// CardPanel.swift
// semel-monitor
//
// One non-activating panel drawing one card: it floats over every space, never takes the
// keyboard or brings the app forward, and reports a click and the pointer coming and
// going. What it says is `CardText`'s.

import AppKit
import SemelMonitor

final class CardPanel: NSPanel {

    static let width: CGFloat = 340

    let cardID: Int
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    private(set) var card: Card

    init(card: Card) {
        self.cardID = card.id
        self.card   = card
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel        = true
        level                  = .statusBar
        backgroundColor        = .clear
        isOpaque               = false
        hasShadow              = true
        hidesOnDeactivate      = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior     = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        draw(card)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ newCard: Card) {
        guard newCard != card else {
            return
        }
        card = newCard
        draw(newCard)
    }

    private func draw(_ card: Card) {
        let view = CardView(card: card)
        view.onClick = { [weak self] in self?.onClick() }
        view.onHover = { [weak self] in self?.onHover($0) }
        contentView = view
        setContentSize(view.fittingSize)
    }
}

/// The card's face: a coloured mark and the headline, then each line of `CardText` in
/// the style of its kind.
private final class CardView: NSVisualEffectView {

    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    private static let padding: CGFloat = 12

    init(card: Card) {
        super.init(frame: NSRect(x: 0, y: 0, width: CardPanel.width, height: 60))
        material     = .popover
        blendingMode = .behindWindow
        state        = .active
        wantsLayer   = true
        layer?.cornerRadius  = 14
        layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(headlineRow(card))
        let textWidth = CardPanel.width - 2 * Self.padding
        if let diagnostic = CardText.diagnosticLine(of: card) {
            stack.addArrangedSubview(label(diagnostic, font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                                           lines: 3, width: textWidth))
        }
        if let names = CardText.namesLine(of: card) {
            stack.addArrangedSubview(label(names, font: .systemFont(ofSize: 12), lines: 2, width: textWidth))
        }
        for secondary in [CardText.countsLine(of: card), CardText.earlierLine(of: card)].compactMap({ $0 }) {
            stack.addArrangedSubview(label(secondary, font: .systemFont(ofSize: 11), colour: .secondaryLabelColor,
                                           lines: 1, width: textWidth))
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: CardPanel.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func headlineRow(_ card: Card) -> NSView {
        let mark = NSView()
        mark.wantsLayer = true
        mark.layer?.cornerRadius    = 4
        mark.layer?.backgroundColor = (card.kind == .errors ? NSColor.systemRed : NSColor.systemGreen).cgColor
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant: 8),
                                     mark.heightAnchor.constraint(equalToConstant: 8)])
        let headline = label(CardText.headline(of: card), font: .boldSystemFont(ofSize: 13), lines: 1,
                             width: CardPanel.width - 2 * Self.padding - 16)
        let row = NSStackView(views: [mark, headline])
        row.orientation = .horizontal
        row.alignment   = .centerY
        row.spacing     = 8
        return row
    }

    private func label(_ text: String, font: NSFont, colour: NSColor = .labelColor, lines: Int, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font                     = font
        field.textColor                = colour
        field.maximumNumberOfLines     = lines
        field.lineBreakMode            = lines == 1 ? .byTruncatingTail : .byWordWrapping
        field.preferredMaxLayoutWidth  = width
        field.isSelectable             = false
        return field
    }

    // MARK: - The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
