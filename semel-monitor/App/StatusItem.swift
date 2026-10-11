// StatusItem.swift
// semel-monitor
//
// The menu bar glyph and its menu: Semel's glyph in the state `StatusGlyph` decides; the
// state and the last settle's line, *Pause notifications* or *Resume*, *Products…*, *Show
// window* (the live window's, greyed until it exists), *Quit*.

import AppKit
import SemelMonitor

final class StatusItem: NSObject {

    var onPause:    () -> Void = {}
    var onResume:   () -> Void = {}
    var onProducts: () -> Void = {}

    private let item         = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateLine    = NSMenuItem(title: "No engine", action: nil, keyEquivalent: "")
    private let pauseItem    = NSMenuItem(title: "Pause notifications", action: #selector(togglePause), keyEquivalent: "")
    private let productsItem = NSMenuItem(title: "Products…", action: #selector(showProducts), keyEquivalent: "")
    private var isPaused     = false

    override init() {
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(stateLine)
        stateLine.isEnabled = false
        menu.addItem(.separator())
        pauseItem.target    = self
        productsItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(productsItem)
        let showWindow = NSMenuItem(title: "Show window", action: nil, keyEquivalent: "")
        showWindow.isEnabled = false
        menu.addItem(showWindow)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit semel-monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        show(state: .noEngine, glyph: .noEngine, isPaused: false, lastSettle: nil)
    }

    func show(state: EngineSubscription.State, glyph: StatusGlyph, isPaused: Bool, lastSettle: String?) {
        self.isPaused = isPaused
        switch state {
        case .noEngine:
            stateLine.title = "No engine"
        case .connected:
            stateLine.title = lastSettle.map { "Connected · last settle: \($0)" } ?? "Connected"
        }
        item.button?.image   = GlyphImage.image(for: glyph)
        item.button?.toolTip = "semel · \(stateLine.title)"
        pauseItem.title = isPaused ? "Resume" : "Pause notifications"
    }

    @objc private func togglePause() {
        isPaused ? onResume() : onPause()
    }

    @objc private func showProducts() {
        onProducts()
    }
}
