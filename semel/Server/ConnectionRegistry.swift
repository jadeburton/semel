// ConnectionRegistry.swift
// SemelServer
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
        // An event carries everything in its JSON, so the cap on that section is the whole
        // event budget, and a wide failure cascade is the traffic that reaches it. Nobody
        // is waiting on an event, so an over-size one is dropped rather than closing every
        // subscriber's connection over a diagnostic — but it is dropped out loud, and here
        // rather than in `ServerConnection`, where one lost event would print once per
        // subscriber.
        guard frame.json.count <= Int(Frame.maximumJSONLength) else {
            let line = "semelserv: dropped a \(Self.name(of: event)) event of \(frame.json.count) bytes; "
                     + "one event may carry \(Frame.maximumJSONLength)\n"
            FileHandle.standardError.write(Data(line.utf8))
            return
        }
        let subscribed = lock.withLock { connections.values.filter { $0.session.isSubscribed } }
        for connection in subscribed {
            connection.deliver(frame)
        }
    }

    /// What to call an event in that line. Spelled out rather than reflected off the case
    /// name, so renaming a case does not quietly rename what the log says.
    private static func name(of event: Event) -> String {
        switch event {
        case .daemon(.errors):  return "errors"
        case .daemon(.notice):  return "notice"
        case .daemon(.settled): return "settled"
        }
    }
}
