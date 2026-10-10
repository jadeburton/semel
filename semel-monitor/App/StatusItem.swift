// StatusItem.swift
// semel-monitor
//
// The menu bar glyph and its menu: a hollow circle with no engine, a filled one connected;
// the state and the last settle's line, *Pause notifications* or *Resume*, *Quit*.

import AppKit
import SemelMonitor

final class StatusItem: NSObject {

    var onPause:  () -> Void = {}
    var onResume: () -> Void = {}

    private let item      = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateLine = NSMenuItem(title: "No engine", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause notifications", action: #selector(togglePause), keyEquivalent: "")
    private var isPaused  = false

    override init() {
        super.init()
        let menu = NSMenu()
        menu.addItem(stateLine)
        menu.addItem(.separator())
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit semel-monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        show(state: .noEngine, isPaused: false, lastSettle: nil)
    }

    func show(state: EngineSubscription.State, isPaused: Bool, lastSettle: String?) {
        self.isPaused = isPaused
        let symbol: String
        switch state {
        case .noEngine:
            symbol = "circle"
            stateLine.title = "No engine"
        case .connected:
            symbol = "circle.fill"
            stateLine.title = lastSettle.map { "Connected · last settle: \($0)" } ?? "Connected"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: stateLine.title)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "semel · \(stateLine.title)"
        pauseItem.title = isPaused ? "Resume" : "Pause notifications"
    }

    @objc private func togglePause() {
        isPaused ? onResume() : onPause()
    }
}
