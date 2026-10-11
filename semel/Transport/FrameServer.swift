// FrameServer.swift
// SemelTransport
//
// The listening half of a server: a listener on an endpoint, one `ServerConnection` per
// client with a service of its own, the fan-out of events to the clients that asked, and
// the process-level rules around a socket file — probe one that is already there, refuse to
// run twice, stop when the file goes, and unwind every connection on stop. A server says
// what its requests mean through `ConnectionService`; everything here is the same for the
// engine's server and a cache's.

import Foundation
import Network
import SemelProtocol

public enum FrameServerError: Error, Equatable, CustomStringConvertible {
    /// A server already answers at the socket path.
    case alreadyAnswered(path: String)
    case cannotListen(endpoint: String, underlying: String)

    public var description: String {
        switch self {
        case .alreadyAnswered(let path):
            return "a server is already answering at \(path)"
        case .cannotListen(let endpoint, let underlying):
            return "cannot listen at \(endpoint): \(underlying)"
        }
    }
}

public final class FrameServer {

    public let endpoint: Endpoint

    /// The program's name, for the queues it labels and the lines it logs: `semelserv`.
    private let name: String
    private let makeService: () -> any ConnectionService
    private let queue: DispatchQueue
    private let lock = NSLock()

    /// Under `lock`.
    private var listener: SocketListener?
    private var connections: [ObjectIdentifier: ServerConnection] = [:]
    private var stopping = false
    /// On `queue`.
    private var connectionCounter = 0

    /// One member per live client connection, left when the connection's service has been
    /// told its client went. `stop` waits on it so a shutdown does not cut a reply in half.
    private let liveConnections = DispatchGroup()

    /// Under `lock`. The socket file as the listener created it, and the watch on its
    /// directory; see `watchSocketFile`.
    private var socketIdentity: FileIdentity?
    private var socketWatch: DispatchSourceFileSystemObject?

    /// Run on the listener's queue when the socket file is deleted, renamed away or
    /// replaced while the server is listening, unless the server is already stopping.
    public var onSocketFileRemoved: (() -> Void)?

    /// Run on the starting thread after the listener has created the socket file and
    /// before the watch on it begins: the window a test has to reach to remove the file
    /// the way a quick client can.
    public var socketFileWatchWillStart: (() -> Void)?

    /// `makeService` is called on the listener's queue for each client that connects.
    public init(endpoint: Endpoint, name: String, makeService: @escaping () -> any ConnectionService) {
        self.endpoint    = endpoint
        self.name        = name
        self.makeService = makeService
        self.queue       = DispatchQueue(label: name + ".listener")
    }

    public var connectionCount: Int {
        lock.withLock { connections.count }
    }

    /// True once `stop` or `markStopping` has been called; no connection is accepted after.
    public var isStopping: Bool {
        lock.withLock { stopping }
    }

    /// Takes no new connection from now on, without closing those there are: a server that
    /// is about to end lets the reply in flight leave first.
    public func markStopping() {
        lock.withLock { stopping = true }
    }

    /// The TCP port clients connect to, once the server is listening on one.
    public var port: UInt16? {
        lock.withLock { listener }?.port
    }

    // MARK: - Start and stop

    /// Takes a socket path for this process: checks its length, refuses to run beside a
    /// server that answers there, unlinks a file nothing answers at, and makes sure the
    /// parent directory exists.
    ///
    /// Separate from `start` so that a program can claim the path before it opens anything
    /// else. A second instance must learn it is second while it has touched nothing.
    public static func claimSocket(at path: String) throws {
        do {
            try UnixSocketPath.check(path)
        } catch {
            throw FrameServerError.cannotListen(endpoint: path, underlying: "\(error)")
        }
        if FileManager.default.fileExists(atPath: path) {
            if probe(path: path, timeout: 2) {
                throw FrameServerError.alreadyAnswered(path: path)
            }
            try? FileManager.default.removeItem(atPath: path)
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    /// Listens, claiming the socket path first when the endpoint is one. Blocks until the
    /// listener is ready or has failed. A second claim of a path this process has just
    /// claimed is a file-exists check and nothing more.
    public func start() throws {
        if case .unix(let path) = endpoint {
            try Self.claimSocket(at: path)
        }

        let listener = SocketListener(endpoint: endpoint, queue: queue)
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
            throw FrameServerError.cannotListen(endpoint: endpoint.description,
                                                underlying: "the listener did not become ready within 10 s")
        }
        if let failure {
            lock.withLock { self.listener = nil }
            throw FrameServerError.cannotListen(endpoint: endpoint.description, underlying: "\(failure)")
        }
        if case .unix(let path) = endpoint {
            watchSocketFile(at: path)
        }
    }

    /// Stops accepting, closes every client, waits for the services to be told, and removes
    /// the socket file if it is still the one the listener created. Idempotent.
    ///
    /// The watch is cancelled before the file is removed, so the server's own removal is
    /// never reported back to it as a reason to stop.
    public func stop() {
        let (victim, watch, identity, open) = lock.withLock {
            () -> (SocketListener?, DispatchSourceFileSystemObject?, FileIdentity?, [ServerConnection]) in
            stopping = true
            let current = (listener, socketWatch, socketIdentity, Array(connections.values))
            listener    = nil
            socketWatch = nil
            return current
        }
        watch?.cancel()
        victim?.cancel()
        for connection in open {
            connection.close()
        }
        // A bound, not a guarantee: a connection parked in `wait` cannot answer until the
        // engine settles, and the process must still be able to stop. Two seconds is long
        // enough for a reply already on the wire and short enough not to hang a shutdown.
        _ = liveConnections.wait(timeout: .now() + 2)
        guard case .unix(let path) = endpoint else {
            return
        }
        if identity == nil || FileIdentity(path: path) == identity {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Events

    /// Encodes `event` once and hands it to every client whose service receives events.
    /// Nothing here waits on a client, so the thread reporting the event never blocks on a
    /// slow socket.
    public func deliver(_ event: Event) {
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
            let line = "\(name): dropped a \(Self.name(of: event)) event of \(frame.json.count) bytes; "
                     + "one event may carry \(Frame.maximumJSONLength)\n"
            FileHandle.standardError.write(Data(line.utf8))
            return
        }
        let subscribed = lock.withLock { connections.values.filter { $0.service.receivesEvents } }
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
        case .daemon(.artifacts): return "artifacts"
        case .daemon(.progress):  return "progress"
        }
    }

    // MARK: - Socket file

    /// A server whose socket file is gone can never be reached again, and nothing else
    /// would end it: a client that started it and then crashed, or a user who deleted the
    /// file, leaves it running with no way in. So the server watches the file and stops
    /// when it goes.
    ///
    /// The watch is on the directory, not the file: `open(2)` refuses a socket file with
    /// EOPNOTSUPP even under O_EVTONLY, so there is no descriptor for a vnode source on it.
    /// A directory's vnode reports `.write` whenever an entry is added, removed or renamed,
    /// and `.delete` when the directory itself goes, which covers every way the file can
    /// disappear without a timer. Each event is only a hint to look again; the file is
    /// gone when nothing is at the path or something else is.
    ///
    /// The file exists from the moment the listener binds, before this watch does, and
    /// whoever was waiting for it — a client, a test — may remove it, or its whole
    /// directory, at once. A file already gone when the watch would begin, or gone before
    /// the watch could report it, is gone all the same, so each case is looked at once
    /// the watch is on rather than waiting for an event that already happened.
    private func watchSocketFile(at path: String) {
        socketFileWatchWillStart?()
        let directoryPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let directory     = open(directoryPath, O_EVTONLY)
        guard directory >= 0 else {
            queue.async { [weak self] in self?.socketFileRemoved() }
            return
        }
        guard let identity = FileIdentity(path: path) else {
            close(directory)
            queue.async { [weak self] in self?.socketFileRemoved() }
            return
        }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: directory,
                                                              eventMask: [.write, .delete, .rename],
                                                              queue: queue)
        watch.setEventHandler { [weak self] in self?.socketDirectoryChanged(path: path) }
        watch.setCancelHandler { close(directory) }
        lock.withLock {
            socketIdentity = identity
            socketWatch    = watch
        }
        watch.resume()
        // A removal between reading the identity and the resume raised no event.
        queue.async { [weak self] in self?.socketDirectoryChanged(path: path) }
    }

    private func socketDirectoryChanged(path: String) {
        let identity = lock.withLock { socketIdentity }
        guard FileIdentity(path: path) != identity else {
            return
        }
        socketFileRemoved()
    }

    private func socketFileRemoved() {
        guard !isStopping else {
            return
        }
        onSocketFileRemoved?()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard !isStopping else {
            connection.cancel()
            return
        }
        connectionCounter += 1
        let client = ServerConnection(connection: connection, service: makeService(),
                                      label: "\(name).connection.\(connectionCounter)")
        client.onClose = { [weak self] closed in
            guard let self else {
                return
            }
            _ = lock.withLock { self.connections.removeValue(forKey: ObjectIdentifier(closed)) }
            liveConnections.leave()
        }
        liveConnections.enter()
        lock.withLock { connections[ObjectIdentifier(client)] = client }
        client.start()
    }

    // MARK: - Probe

    /// Whether a server answers `hello` at `path` within `timeout`. A refused or waiting
    /// connection, a timeout, or a close without a reply all mean no.
    public static func probe(path: String, timeout: TimeInterval) -> Bool {
        let queue     = DispatchQueue(label: "semel.probe")
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
}

/// Which file is at a path, as the file system tells files apart: a file deleted and
/// another created at the same path compare unequal. Nil when nothing is there.
struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(path: String) {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            return nil
        }
        device = status.st_dev
        inode  = status.st_ino
    }
}
