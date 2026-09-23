// Server.swift
// SemelServer
//
// The listener and the process-level rules around it: probe a socket file that is
// already there, refuse to run twice, unwind everything on stop, and turn an
// unrecoverable error into a refusal of new work followed by an exit. No signals here;
// the executable wires those.

import Foundation
import Network
import SemelDatabaseModels
import SemelProtocol
import SemelTransport

public enum ServerError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning(path: String)
    case cannotListen(path: String, underlying: String)

    public var description: String {
        switch self {
        case .alreadyRunning(let path):
            return "semelserv is already running at \(path)"
        case .cannotListen(let path, let underlying):
            return "cannot listen at \(path): \(underlying)"
        }
    }
}

/// A handler backs exactly one server; the sink is claimed when the server starts, so a
/// server that fails to start never takes it.
public final class Server {

    private let handler: RequestHandler
    private let socketPath: String
    private let registry = ConnectionRegistry()
    private let queue = DispatchQueue(label: "semelserv.listener")
    private var listener: SocketListener?
    private var connectionCounter = 0
    private let lock = NSLock()
    private var stopping = false
    private var terminating = false

    /// One member per live client connection, left when the connection's session has been
    /// unwound. `stop` waits on it so a shutdown does not cut a reply in half.
    private let liveConnections = DispatchGroup()

    public init(handler: RequestHandler, socketPath: String) {
        self.handler    = handler
        self.socketPath = socketPath
    }

    public var connectionCount: Int {
        registry.count
    }

    /// True once a fatal error or stop has been seen; no new connection is accepted after.
    public var isStopping: Bool {
        lock.withLock { stopping }
    }

    // MARK: - Start and stop

    /// Takes the socket path for this process: checks its length, refuses to run beside a
    /// server that answers there, unlinks a file nothing answers at, and makes sure the
    /// parent directory exists.
    ///
    /// Separate from `start` so that the executable can claim the path before it opens the
    /// graph. A second instance must learn it is second while it has touched nothing.
    public static func claimSocket(at path: String) throws {
        do {
            try UnixSocketPath.check(path)
        } catch {
            throw ServerError.cannotListen(path: path, underlying: "\(error)")
        }
        if FileManager.default.fileExists(atPath: path) {
            if probe(path: path, timeout: 2) {
                throw ServerError.alreadyRunning(path: path)
            }
            try? FileManager.default.removeItem(atPath: path)
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    /// Claims the socket path, then listens. Blocks until the listener is ready or has
    /// failed. A second pass over a path this process has just claimed is a file-exists
    /// check and nothing more.
    public func start() throws {
        try Self.claimSocket(at: socketPath)

        let listener = SocketListener(path: socketPath, queue: queue)
        listener.onConnection = { [weak self] connection in self?.accept(connection) }
        lock.withLock { self.listener = listener }

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.start { result in
            if case .failure(let error) = result {
                failure = error
            }
            ready.signal()
        }
        guard ready.wait(timeout: .now() + 10) == .success else {
            lock.withLock { self.listener = nil }
            listener.cancel()
            throw ServerError.cannotListen(path: socketPath,
                                           underlying: "the listener did not become ready within 10 s")
        }
        if let failure {
            lock.withLock { self.listener = nil }
            throw ServerError.cannotListen(path: socketPath, underlying: "\(failure)")
        }
        handler.eventSink = registry
    }

    /// Stops accepting, closes every client, waits for the sessions to unwind, and removes
    /// the socket file. Idempotent.
    public func stop() {
        let victim = lock.withLock { () -> SocketListener? in
            stopping = true
            let current = listener
            listener = nil
            return current
        }
        victim?.cancel()
        registry.closeAll()
        // A bound, not a guarantee: a connection parked in `wait` cannot answer until the
        // engine settles, and the process must still be able to stop. Two seconds is long
        // enough for a reply already on the wire and short enough not to hang a shutdown.
        _ = liveConnections.wait(timeout: .now() + 2)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Stops the server once and ends the process. Signals, the fatal handler and a test
    /// can all arrive here at the same moment; only the first one through the gate stops
    /// anything or exits.
    public func terminate(code: Int32, exit: (Int32) -> Void = { Foundation.exit($0) }) {
        let alreadyTerminating = lock.withLock { () -> Bool in
            guard !terminating else {
                return true
            }
            terminating = true
            return false
        }
        guard !alreadyTerminating else {
            return
        }
        stop()
        exit(code)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard !isStopping else {
            connection.cancel()
            return
        }
        connectionCounter += 1
        let client = ServerConnection(connection: connection, handler: handler,
                                      label: "semelserv.connection.\(connectionCounter)")
        client.onClose = { [weak self] closed in
            self?.registry.remove(closed)
            self?.liveConnections.leave()
        }
        liveConnections.enter()
        registry.add(client)
        client.start()
    }

    // MARK: - Probe

    /// Whether a server answers `hello` at `path` within `timeout`. A refused or waiting
    /// connection, a timeout, or a close without a reply all mean no.
    static func probe(path: String, timeout: TimeInterval) -> Bool {
        let queue     = DispatchQueue(label: "semelserv.probe")
        let stream    = FrameStream(connection: NWConnection(to: .unix(path: path), using: .tcp), queue: queue)
        let answered  = DispatchSemaphore(value: 0)
        var sawReply  = false
        stream.onFrame = { frame in
            if frame.kind == .response {
                sawReply = true
                answered.signal()
            }
        }
        stream.onClose = { _ in answered.signal() }
        stream.start()
        if let hello = try? Frame.request(.hello(Hello(role: .daemon)), correlationID: 1) {
            try? stream.send(hello)
        }
        _ = answered.wait(timeout: .now() + timeout)
        // Read where it is written: on a timeout the stream's queue may still be mid-frame,
        // and `queue.sync` orders this read after whatever it was doing.
        let answeredWithAReply = queue.sync { sawReply }
        stream.close()
        return answeredWithAReply
    }

    // MARK: - Fatal errors

    /// The machine is broken: log it, take no new work, and terminate once the reply that
    /// was in flight has had a moment to leave. The delay is what lets the handler's
    /// `.unrecoverable` reply reach its client before the process ends.
    public func handleFatal(_ error: any UnrecoverableError, terminate terminateHook: @escaping (Int32) -> Void) {
        FileHandle.standardError.write(Data("semelserv: \(error.unrecoverableDescription)\n".utf8))
        lock.withLock { stopping = true }
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            // EX_SOFTWARE, as FatalErrors.defaultHandler uses.
            terminate(code: 70, exit: terminateHook)
        }
    }
}
