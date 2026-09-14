// Server.swift
// SemelServ
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

public final class Server {

    private let handler: RequestHandler
    private let socketPath: String
    private let registry = ConnectionRegistry()
    private let queue = DispatchQueue(label: "semelserv.listener")
    private var listener: SocketListener?
    private var connectionCounter = 0
    private let lock = NSLock()
    private var stopping = false

    public init(handler: RequestHandler, socketPath: String) {
        self.handler    = handler
        self.socketPath = socketPath
        handler.eventSink = registry
    }

    public var connectionCount: Int {
        registry.count
    }

    /// True once a fatal error or stop has been seen; no new connection is accepted after.
    public var isStopping: Bool {
        lock.withLock { stopping }
    }

    // MARK: - Start and stop

    /// Probes an existing socket file, unlinks it if nothing answers, and listens. Blocks
    /// until the listener is ready or has failed.
    public func start() throws {
        do {
            try UnixSocketPath.check(socketPath)
        } catch {
            throw ServerError.cannotListen(path: socketPath, underlying: "\(error)")
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            if Self.probe(path: socketPath, timeout: 2) {
                throw ServerError.alreadyRunning(path: socketPath)
            }
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let listener = SocketListener(path: socketPath, queue: queue)
        listener.onConnection = { [weak self] connection in self?.accept(connection) }
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.start { result in
            if case .failure(let error) = result {
                failure = error
            }
            ready.signal()
        }
        ready.wait()
        if let failure {
            self.listener = nil
            throw ServerError.cannotListen(path: socketPath, underlying: "\(failure)")
        }
    }

    /// Stops accepting, closes every client, and removes the socket file. Idempotent.
    public func stop() {
        lock.withLock { stopping = true }
        listener?.cancel()
        listener = nil
        registry.closeAll()
        try? FileManager.default.removeItem(atPath: socketPath)
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
        client.onClose = { [weak self] closed in self?.registry.remove(closed) }
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
            stream.send(hello)
        }
        _ = answered.wait(timeout: .now() + timeout)
        stream.close()
        return sawReply
    }

    // MARK: - Fatal errors

    /// The machine is broken: log it, take no new work, and terminate once the reply that
    /// was in flight has had a moment to leave. The delay is what lets the handler's
    /// `.unrecoverable` reply reach its client before the process ends.
    public func handleFatal(_ error: any UnrecoverableError, terminate: @escaping (Int32) -> Void) {
        FileHandle.standardError.write(Data("semelserv: \(error.unrecoverableDescription)\n".utf8))
        lock.withLock { stopping = true }
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            stop()
            terminate(70) // EX_SOFTWARE, as FatalErrors.defaultHandler uses
        }
    }
}
