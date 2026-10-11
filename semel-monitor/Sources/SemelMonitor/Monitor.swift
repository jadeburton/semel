// Monitor.swift
// SemelMonitor
//
// The planner, the subscription and the clock's one timer, wired together on the main
// queue. The two front ends — the panels and `--print` — are the `onChanges` and
// `onState` they pass; neither decides anything.

import Foundation
import SemelProtocol

public final class Monitor {

    public let planner: NotificationPlanner

    /// The connection's state as last reported; `noEngine` until the first connection.
    public private(set) var state = EngineSubscription.State.noEngine

    /// What became of the cards, after every event, click, hover and expiry.
    public var onChanges: ([CardChange]) -> Void = { _ in }

    /// The connection came or went.
    public var onState: (EngineSubscription.State) -> Void = { _ in }

    /// The products window is to open: for the card clicked, or nil for *Products…*.
    public var onOpenWindow: (Card?) -> Void = { _ in }

    /// A settle ended — its `settled` or its `artifacts` arrived — so what `output:` holds
    /// may have moved: an open products window reads it again.
    public var onSettle: () -> Void = {}

    private let clock: any Clock
    private var subscription: EngineSubscription?
    private var timer: DispatchWorkItem?

    public init(configuration: MonitorConfiguration, clock: any Clock) {
        self.clock   = clock
        self.planner = NotificationPlanner(clock: clock, only: configuration.only)
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

    /// A click on a card: the products window opens for its settle, and the card goes.
    public func click(cardID: Int) {
        guard let card = planner.cards.first(where: { $0.id == cardID }) else {
            return
        }
        dismiss(cardID: cardID)
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
        apply { $0.receive(event) }
        switch event {
        case .settled, .artifacts:
            onSettle()
        case .errors, .progress, .notice:
            break
        }
    }

    private func changeState(to newState: EngineSubscription.State) {
        if newState == .noEngine {
            planner.engineLost()
        }
        state = newState
        onState(newState)
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
