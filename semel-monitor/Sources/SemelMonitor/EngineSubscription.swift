// EngineSubscription.swift
// SemelMonitor
//
// The monitor's one connection: opened as `semel` opens one, subscribed, and opened again
// whenever it drops. It sends `hello` and `subscribe` and nothing else — no push, no
// build, no removal — and it never starts a server: an observer that brought an engine up
// would be deciding something for whoever runs the next `semel`.

import Foundation
import SemelCLI
import SemelProtocol

public final class EngineSubscription {

    public enum State: Equatable, Sendable {
        case noEngine
        case connected
    }

    public enum SubscribeError: Error, CustomStringConvertible {
        case refused(ErrorResponse)
        case unexpectedReply

        public var description: String {
            switch self {
            case .refused(let response): return "the server refused the subscription: \(response)"
            case .unexpectedReply:       return "the server did not answer the subscription"
            }
        }
    }

    /// The first wait after a failed attempt, and the longest: the watcher's backoff
    /// (`Watcher.openSession`), doubling from a quarter of a second to five.
    static let firstReconnectDelay   = Duration.milliseconds(250)
    static let longestReconnectDelay = Duration.seconds(5)

    /// How often an open connection is asked whether it still is. The socket closes
    /// without telling anyone but its waiters, and a subscriber waits on nothing.
    static let liveCheckInterval = Duration.milliseconds(250)

    private let socketPath: String
    private let queue: DispatchQueue
    private let onState: (State) -> Void
    private let onEvent: (DaemonEvent) -> Void

    /// `onState` and `onEvent` are called on `queue`, in the order the server sent the
    /// events: the planner reads a settle's three events as one.
    public init(socketPath: String, queue: DispatchQueue = .main,
                onState: @escaping (State) -> Void, onEvent: @escaping (DaemonEvent) -> Void) {
        self.socketPath = socketPath
        self.queue      = queue
        self.onState    = onState
        self.onEvent    = onEvent
    }

    /// Runs for the life of the process, on a thread of its own.
    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "semel-monitor.subscription"
        thread.start()
    }

    private func run() {
        var delay = Self.firstReconnectDelay
        var state: State?
        while true {
            do {
                let connection = try subscribe()
                deliver(.connected, replacing: &state)
                delay = Self.firstReconnectDelay
                while connection.isOpen {
                    Thread.sleep(forTimeInterval: Self.liveCheckInterval.timeInterval)
                }
                deliver(.noEngine, replacing: &state)
            } catch {
                deliver(.noEngine, replacing: &state)
                Thread.sleep(forTimeInterval: delay.timeInterval)
                delay = min(delay * 2, Self.longestReconnectDelay)
            }
        }
    }

    private func deliver(_ newState: State, replacing state: inout State?) {
        guard newState != state else {
            return
        }
        state = newState
        queue.async { [onState] in onState(newState) }
    }

    /// One connection, through the handshake, with events flowing to `onEvent`. The
    /// handler is set before `subscribe` leaves, so no event the subscription starts is
    /// missed.
    private func subscribe() throws -> SocketConnection {
        let connection = try SocketConnection.connect(to: socketPath)
        do {
            let (reply, _) = try connection.send(.hello(Hello(role: .daemon)), body: nil)
            guard case .hello(let helloResponse) = reply else {
                throw ConnectError.unexpectedReply
            }
            if case .rejected(let reason) = helloResponse {
                throw ConnectError.rejected(reason)
            }
            connection.onEvent = { [queue, onEvent] event in
                switch event {
                case .daemon(let daemonEvent):
                    queue.async { onEvent(daemonEvent) }
                }
            }
            let (subscribed, _) = try connection.send(.daemon(.subscribe), body: nil)
            switch subscribed {
            case .daemon:            return connection
            case .error(let error):  throw SubscribeError.refused(error)
            case .hello:             throw SubscribeError.unexpectedReply
            }
        } catch {
            connection.close()
            throw error
        }
    }
}
