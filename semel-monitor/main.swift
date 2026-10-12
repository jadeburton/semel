//
//  main.swift
//  semel-monitor
//
//  A fifth client of `semelserv`, observing (B-150): it subscribes to the engine's events
//  and shows each settle that moved a product or broke one as a card at the top right of
//  the screen, and a settle still running as one card updated in place. It changes nothing
//  in the engine and starts none; with no engine running its status item says so and it
//  waits. A click on a card, or *Products…*, opens the products window: `output:` as `ls`
//  lists it, and an export of what is selected. *Show window*, or a click on the running
//  card, opens the live window: the nodes running now, the queue and the counts, and the
//  last settle's products and errors.
//
//  `--print` runs the same model with no panels and writes each card as lines on
//  standard output, which is what the end-to-end test reads and what a script can tail.
//  Lines on its standard input stand for a person's clicks — `click` the card on top,
//  `products` and `show` the menu items — and the windows they open are written as lines
//  too.
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

let clock      = SystemClock()
let monitor    = Monitor(configuration: configuration, clock: clock)
let socketPath = SemelPaths.serverSocket.path
let presenter  = ProductsPresenter(source: EngineProducts(socketPath: socketPath))

// The products window opens for the card clicked, or for *Products…* with the newest
// card's marks; an open window reads `output:` again after every settle.
monitor.onOpenWindow = { card in presenter.open(for: card, marks: card ?? monitor.planner.lastCard) }
monitor.onSettle     = { presenter.settleEnded(marks: monitor.planner.lastCard) }

guard !configuration.prints else {
    var printedState: EngineSubscription.State?
    let printer = CardPrinter(clock: clock)
    monitor.onChanges = { changes in
        printer.lines(for: changes).forEach { print($0) }
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
    // The live window as lines, once, as it stands when it would open.
    monitor.onShowLive = {
        LiveWindowText.lines(for: monitor.live, at: monitor.now).forEach { print($0) }
    }
    // The products window as lines, once, when it would open; with no window to keep up
    // to date, the presenter is closed again and reads nothing more.
    presenter.onDisplay = { display, isOpening in
        guard isOpening else {
            return
        }
        switch display {
        case .shown(let model):
            ProductsWindowText.lines(for: model, openedFor: presenter.openedFor).forEach { print($0) }
        case .failed(let reason):
            ProductsWindowText.lines(failing: reason, openedFor: presenter.openedFor).forEach { print($0) }
        case .closed, .loading:
            return
        }
        presenter.close()
    }
    let inputReader = Thread {
        while let line = readLine() {
            let command = line.trimmingCharacters(in: .whitespaces)
            DispatchQueue.main.async {
                switch command {
                case "click":    monitor.clickNewestCard()
                case "products": monitor.openProducts()
                case "show":     monitor.showLive()
                case "":         break
                default:         FileHandle.standardError.write(Data("semel-monitor: not an input: \(command)\n".utf8))
                }
            }
        }
    }
    inputReader.name = "semel-monitor.input"
    inputReader.start()
    monitor.start(socketPath: socketPath)
    dispatchMain()
}

// MARK: - The app

let application = NSApplication.shared
// An accessory: no Dock icon, no menu bar of its own, never the frontmost app.
application.setActivationPolicy(.accessory)
// Never shown, an accessory's main menu still carries the key equivalents the products
// window answers: copy from the errors, select all, close.
application.mainMenu = MainMenu.make()

let statusItem     = StatusItem()
let cardStack      = CardStack()
let productsWindow = ProductsWindow()
let liveWindow     = LiveWindow()

func refreshStatus() {
    statusItem.show(state: monitor.state,
                    glyph: StatusGlyph.of(state: monitor.state, holdsErrors: monitor.planner.holdsErrorCard,
                                          settle: monitor.planner.settleInProgress),
                    isPaused: monitor.planner.isPaused,
                    lastSettle: monitor.planner.lastCard.map(CardText.summary(of:)))
}

statusItem.onPause      = { monitor.pause() }
statusItem.onResume     = { monitor.resume() }
statusItem.onProducts   = { monitor.openProducts() }
statusItem.onShowWindow = { monitor.showLive() }
cardStack.onClick       = { monitor.click(cardID: $0) }
cardStack.onHover       = { cardID, isOver in
    isOver ? monitor.pointerEntered(cardID: cardID) : monitor.pointerLeft(cardID: cardID)
}
monitor.onChanges = { _ in
    cardStack.show(monitor.planner.cards)
    refreshStatus()
}
monitor.onState = { _ in refreshStatus() }
monitor.onEvent = {
    refreshStatus()
    liveWindow.refresh()
}
monitor.onOpenWindow = { card in
    presenter.open(for: card, marks: card ?? monitor.planner.lastCard)
    productsWindow.say("")
    productsWindow.show()
}
monitor.onShowLive = { liveWindow.show() }
liveWindow.read = { (monitor.live, monitor.now) }

presenter.onDisplay = { display, _ in productsWindow.show(display) }
productsWindow.onSelectSection = { presenter.select($0) }
productsWindow.onSelectRows    = { presenter.selectRows($0) }
productsWindow.onClose         = { presenter.close() }
productsWindow.onExport        = { request in
    ExportPanel.run(request, over: productsWindow.window) { destination in
        productsWindow.say("Exporting into \(destination)…")
        presenter.export(request, into: destination) { result in
            productsWindow.say(ExportPanel.outcome(of: result, into: destination))
        }
    }
}

monitor.start(socketPath: socketPath)
application.run()
