//
//  main.swift
//  semel-monitor
//
//  A fifth client of `semelserv`, observing (B-150): it subscribes to the engine's events
//  and shows each settle that moved a product or broke one as a card at the top right of
//  the screen. It changes nothing in the engine and starts none; with no engine running
//  its status item says so and it waits.
//
//  `--print` runs the same model with no panels and writes each card as lines on
//  standard output, which is what the end-to-end test reads and what a script can tail.
//
//  Focus: `NSWorkspace` has no public way to ask whether a Focus mode is on, and the one
//  public API, `INFocusStatusCenter`, answers only a bundled app the person has
//  authorised. So the monitor does not read Focus; *Pause notifications* is the switch.
//

import AppKit
import Foundation
import SemelMonitor
import SemelNodeKit

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("semel-monitor: \(message)\n".utf8))
    exit(status)
}

// Line by line into a pipe: a reader tailing `--print` wants each card as it comes.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(MonitorConfiguration.usage)
    exit(0)
}

let configuration: MonitorConfiguration
do {
    configuration = try MonitorConfiguration.parse(arguments)
} catch {
    fail("\(error)\n\(MonitorConfiguration.usage)", status: 2)
}

let monitor    = Monitor(configuration: configuration, clock: SystemClock())
let socketPath = SemelPaths.serverSocket.path

guard !configuration.prints else {
    var printedState: EngineSubscription.State?
    monitor.onChanges = { changes in
        changes.flatMap(CardText.printed).forEach { print($0) }
    }
    monitor.onState = { state in
        guard state != printedState else {
            return
        }
        printedState = state
        switch state {
        case .connected: print("status: connected")
        case .noEngine:  print("status: no engine")
        }
    }
    monitor.start(socketPath: socketPath)
    dispatchMain()
}

// MARK: - The app

let application = NSApplication.shared
// An accessory: no Dock icon, no menu bar of its own, never the frontmost app.
application.setActivationPolicy(.accessory)

let statusItem = StatusItem()
let cardStack  = CardStack()

func refreshStatus() {
    statusItem.show(state: monitor.state, isPaused: monitor.planner.isPaused,
                    lastSettle: monitor.planner.lastCard.map(CardText.summary(of:)))
}

statusItem.onPause  = { monitor.pause() }
statusItem.onResume = { monitor.resume() }
cardStack.onClick   = { monitor.dismiss(cardID: $0) }
cardStack.onHover   = { cardID, isOver in
    isOver ? monitor.pointerEntered(cardID: cardID) : monitor.pointerLeft(cardID: cardID)
}
monitor.onChanges = { _ in
    cardStack.show(monitor.planner.cards)
    refreshStatus()
}
monitor.onState = { _ in refreshStatus() }
monitor.start(socketPath: socketPath)
application.run()
