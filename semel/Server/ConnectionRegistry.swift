// ConnectionRegistry.swift
// SemelServ
//
// The live connections, and the handler's event sink. An event is encoded once and
// handed to every subscribed connection's stream; nothing here waits on a client, so the
// engine's reporting thread never blocks on a slow socket.

import Foundation
import SemelProtocol

final class ConnectionRegistry: EventSink {

    private let lock = NSLock()
    private var connections: [ObjectIdentifier: ServerConnection] = [:]

    var count: Int {
        lock.withLock { connections.count }
    }

    func add(_ connection: ServerConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
    }

    func remove(_ connection: ServerConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    /// Closes every connection; each one ends its own session as it goes.
    func closeAll() {
        let all = lock.withLock { Array(connections.values) }
        for connection in all {
            connection.close()
        }
    }

    // MARK: - EventSink

    func deliver(_ event: Event) {
        guard let frame = try? Frame.event(event) else {
            return
        }
        let subscribed = lock.withLock { connections.values.filter { $0.session.isSubscribed } }
        for connection in subscribed {
            connection.deliver(frame)
        }
    }
}
