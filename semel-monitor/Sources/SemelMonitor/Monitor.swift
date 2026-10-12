// Monitor.swift
// SemelMonitor
//
// The planner, the live window's model, the subscription and the clock's one timer, wired
// together on the main queue. The two front ends — the panels and `--print` — are the
// callbacks they pass; neither decides anything.

import Foundation
import SemelProtocol

public final class Monitor {

    public let planner: NotificationPlanner

    /// What the live window shows, kept from every event whether the window is open or
    /// not: how long a node has run is measured from the record that first listed it.
    public private(set) var live = LiveWindowModel()

    /// The connection's state as last reported; `noEngine` until the first connection.
    public private(set) var state = EngineSubscription.State.noEngine

    /// What became of the cards, after every event, click, hover and expiry.
    public var onChanges: ([CardChange]) -> Void = { _ in }

    /// The connection came or went.
    public var onState: (EngineSubscription.State) -> Void = { _ in }

    /// The products window is to open: for the card clicked, or nil for *Products…*.
    public var onOpenWindow: (Card?) -> Void = { _ in }

    /// The live window is to open: *Show window*, or a click on the running card.
    public var onShowLive: () -> Void = {}

    /// A settle ended — its `settled` or its `artifacts` arrived — so what `output:` holds
    /// may have moved: an open products window reads it again.
    public var onSettle: () -> Void = {}

    /// Any event arrived, or the connection came or went: the live window and the status
    /// item's settling state follow every `progress`, which moves no card under a pause.
    public var onEvent: () -> Void = {}

    private let clock: any Clock
    private var subscription: EngineSubscription?
    private var timer: DispatchWorkItem?

    public init(configuration: MonitorConfiguration, clock: any Clock) {
        self.clock   = clock
        self.planner = NotificationPlanner(clock: clock, only: configuration.only)
    }

    /// The app's clock now: what the live window measures elapsed time against.
    public var now: Duration {
        clock.now
    }

    /// Subscribes at `socketPath`, and keeps subscribing. Call on the main queue.
    public func start(socketPath: String) {
        let subscription = EngineSubscription(socketPath: socketPath,
                                              onState: { [weak self] in self?.changeState(to: $0) },
                                              onEvent: { [weak self] event in self?.receive(event) })
        self.subscription = subscription
        subscription.start()
    }

    // MARK: - What the person does

    public func dismiss(cardID: Int) {
        apply { $0.dismiss(cardID: cardID) }
    }

    /// A click on a card: the window for it opens, and the card goes — the products
    /// window for a settle's result or errors, the live window for a settle still running.
    public func click(cardID: Int) {
        guard let card = planner.cards.first(where: { $0.id == cardID }) else {
            return
        }
        dismiss(cardID: cardID)
        guard card.kind != .running else {
            onShowLive()
            return
        }
        onOpenWindow(card)
    }

    /// A click on the newest card on screen, the one on top: what `click` on `--print`'s
    /// standard input means.
    public func clickNewestCard() {
        guard let newest = planner.cards.first else {
            return
        }
        click(cardID: newest.id)
    }

    /// *Products…*.
    public func openProducts() {
        onOpenWindow(nil)
    }

    /// *Show window*.
    public func showLive() {
        onShowLive()
    }

    public func pointerEntered(cardID: Int) {
        planner.pointerEntered(cardID: cardID)
        scheduleNextDeadline()
    }

    public func pointerLeft(cardID: Int) {
        apply { $0.pointerLeft(cardID: cardID) }
    }

    public func pause() {
        planner.pause()
        onState(state)
    }

    public func resume() {
        apply { $0.resume() }
        onState(state)
    }

    // MARK: - Internals

    private func receive(_ event: DaemonEvent) {
        live.receive(event, at: clock.now)
        apply { $0.receive(event) }
        onEvent()
        switch event {
        case .settled, .artifacts:
            onSettle()
        case .errors, .progress, .notice:
            break
        }
    }

    private func changeState(to newState: EngineSubscription.State) {
        switch newState {
        case .noEngine:
            live.engineLost()
            apply { $0.engineLost() }
        case .connected:
            live.connected()
        }
        state = newState
        onState(newState)
        onEvent()
    }

    private func apply(_ step: (NotificationPlanner) -> [CardChange]) {
        let changes = step(planner)
        if !changes.isEmpty {
            onChanges(changes)
        }
        scheduleNextDeadline()
    }

    /// One pending wake-up, at the planner's next deadline: the only place the monitor
    /// waits on the clock.
    private func scheduleNextDeadline() {
        timer?.cancel()
        timer = nil
        guard let deadline = planner.nextDeadline else {
            return
        }
        let wait = max(.zero, deadline - clock.now)
        let item = DispatchWorkItem { [weak self] in self?.apply { $0.advance() } }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait.timeInterval, execute: item)
    }
}
