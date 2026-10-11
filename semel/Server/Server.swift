// Server.swift
// SemelServer
//
// The engine's server: the request handler behind `SemelTransport`'s listener, one session
// per client, and the process-level rules that are the engine's — refuse to run twice under
// the name `semelserv`, and turn an unrecoverable error into a refusal of new work followed
// by an exit. The listener, the connections and the socket file's watch are the transport's.
// No signals here; the executable wires those.

import Foundation
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

    /// The transport's refusal, in the engine server's words.
    init(_ error: FrameServerError) {
        switch error {
        case .alreadyAnswered(let path):
            self = .alreadyRunning(path: path)
        case .cannotListen(let endpoint, let underlying):
            self = .cannotListen(path: endpoint, underlying: underlying)
        }
    }
}

/// A handler backs exactly one server; the sink is claimed when the server starts, so a
/// server that fails to start never takes it.
public final class Server {

    private let handler: RequestHandler
    private let socketPath: String
    private let listener: FrameServer
    private let lock = NSLock()
    private var terminating = false

    /// Where the handler's events go: the clients that subscribed. Held here, since the
    /// handler holds its sink weakly.
    private let events: EventFanOut

    /// Run on the listener's queue when the socket file is deleted, renamed away or
    /// replaced while the server is listening. Unset, the server terminates with code 0;
    /// the executable sets it so the stop is the same one its signals take.
    public var onSocketFileRemoved: (() -> Void)?

    /// Run on the starting thread after the listener has created the socket file and
    /// before the watch on it begins: the window a test has to reach to remove the file
    /// the way a quick client can.
    var socketFileWatchWillStart: (() -> Void)? {
        get { listener.socketFileWatchWillStart }
        set { listener.socketFileWatchWillStart = newValue }
    }

    public init(handler: RequestHandler, socketPath: String) {
        let listener = FrameServer(endpoint: .unix(path: socketPath), name: "semelserv") {
            SessionService(handler: handler)
        }
        self.handler    = handler
        self.socketPath = socketPath
        self.listener   = listener
        self.events     = EventFanOut(listener: listener)
        listener.onSocketFileRemoved = { [weak self] in self?.socketFileRemoved() }
    }

    public var connectionCount: Int {
        listener.connectionCount
    }

    /// True once a fatal error or stop has been seen; no new connection is accepted after.
    public var isStopping: Bool {
        listener.isStopping
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
            try FrameServer.claimSocket(at: path)
        } catch let error as FrameServerError {
            throw ServerError(error)
        }
    }

    /// Claims the socket path, then listens. Blocks until the listener is ready or has
    /// failed.
    public func start() throws {
        do {
            try listener.start()
        } catch let error as FrameServerError {
            throw ServerError(error)
        }
        handler.eventSink = events
    }

    /// Stops accepting, closes every client, waits for the sessions to unwind, and removes
    /// the socket file if it is still the one the listener created. Idempotent.
    public func stop() {
        listener.stop()
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

    private func socketFileRemoved() {
        if let onSocketFileRemoved {
            onSocketFileRemoved()
        } else {
            terminate(code: 0)
        }
    }

    // MARK: - Fatal errors

    /// The machine is broken: log it, take no new work, and terminate once the reply that
    /// was in flight has had a moment to leave. The delay is what lets the handler's
    /// `.unrecoverable` reply reach its client before the process ends.
    public func handleFatal(_ error: any UnrecoverableError, terminate terminateHook: @escaping (Int32) -> Void) {
        FileHandle.standardError.write(Data("semelserv: \(error.unrecoverableDescription)\n".utf8))
        listener.markStopping()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
            // EX_SOFTWARE, as FatalErrors.defaultHandler uses.
            terminate(code: 70, exit: terminateHook)
        }
    }
}

// MARK: - One client

/// What the engine's server does with one client's requests: the handler answers them under
/// the client's session, and a `wait` blocks until the graph settles, so it is answered off
/// the connection's queue.
final class SessionService: ConnectionService {

    let session = Session()
    private let handler: RequestHandler

    init(handler: RequestHandler) {
        self.handler = handler
    }

    var receivesEvents: Bool {
        session.isSubscribed
    }

    func prepare(_ request: Request, body: Data?) -> PreparedAnswer {
        let prepared = handler.prepare(request, body: body)
        let blocks: Bool
        if case .daemon(.wait) = request {
            blocks = true
        } else {
            blocks = false
        }
        return PreparedAnswer(blocks: blocks) { [handler, session] parts in
            handler.handle(prepared, session: session, replyStream: parts)
        }
    }

    /// Commits whatever batch the client left open, so a client killed mid-push cannot
    /// leave the engine's work signals suppressed.
    func connectionEnded() {
        handler.endSession(session)
    }
}

/// The handler's event sink over the listener's clients: an event goes to every client
/// whose session subscribed.
private final class EventFanOut: EventSink {

    private let listener: FrameServer

    init(listener: FrameServer) {
        self.listener = listener
    }

    func deliver(_ event: Event) {
        listener.deliver(event)
    }
}
