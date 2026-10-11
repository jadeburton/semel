// Monitor.swift
// SemelMonitor
//
// The planner, the subscription and the clock's one timer, wired together on the main
// queue. The two front ends — the panels and `--print` — are the `onChanges` and
// `onState` they pass; neither decides anything.

import Foundation

public final class Monitor {

    public let planner: NotificationPlanner

    /// The connection's state as last reported; `noEngine` until the first connection.
    public private(set) var state = EngineSubscription.State.noEngine

    /// What became of the cards, after every event, click, hover and expiry.
    public var onChanges: ([CardChange]) -> Void = { _ in }

    /// The connection came or went.
    public var onState: (EngineSubscription.State) -> Void = { _ in }

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
                                              onEvent: { [weak self] event in self?.apply { $0.receive(event) } })
        self.subscription = subscription
        subscription.start()
    }

    // MARK: - What the person does

    public func dismiss(cardID: Int) {
        apply { $0.dismiss(cardID: cardID) }
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
