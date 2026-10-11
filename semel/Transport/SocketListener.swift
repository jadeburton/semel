// SocketListener.swift
// SemelTransport
//
// An NWListener bound to an endpoint: a Unix-domain socket path, or a TCP host and port.
// For a path, the listener creates the socket file when it becomes ready and does not
// remove it when cancelled; the owner does that, because only the owner knows whether the
// file is still its own.

import Foundation
import Network

public final class SocketListener {

    /// Called on `queue` for each accepted connection, not yet started.
    public var onConnection: ((NWConnection) -> Void)?

    public let endpoint: Endpoint

    private let queue: DispatchQueue
    private let lock = NSLock()

    /// Under `lock`: `start` runs on the caller's thread while `cancel` is reachable from a
    /// signal handler's queue and from the owner's.
    private var listener: NWListener?

    public init(endpoint: Endpoint, queue: DispatchQueue) {
        self.endpoint = endpoint
        self.queue    = queue
    }

    public convenience init(path: String, queue: DispatchQueue) {
        self.init(endpoint: .unix(path: path), queue: queue)
    }

    /// The socket path, for a listener on one.
    public var path: String? {
        guard case .unix(let path) = endpoint else {
            return nil
        }
        return path
    }

    /// The TCP port connections are accepted on once the listener is ready — the one the
    /// system chose, when the endpoint asked for port 0. Nil for a socket path, and before
    /// the listener is ready.
    public var port: UInt16? {
        guard case .tcp = endpoint else {
            return nil
        }
        return lock.withLock { listener?.port?.rawValue }
    }

    /// Binds and listens. `ready` is called once, on `queue`, when connections are being
    /// accepted — for a path, when the socket file exists — or with the error that
    /// prevented it.
    public func start(ready: @escaping (Result<Void, Error>) -> Void) {
        let endpoint = self.endpoint
        do {
            try endpoint.check()
        } catch {
            queue.async { ready(.failure(error)) }
            return
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: endpoint.listenerParameters)
        } catch {
            queue.async { ready(.failure(TransportError.listenFailed(path: endpoint.description, underlying: "\(error)"))) }
            return
        }
        lock.withLock { self.listener = listener }

        var reported = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !reported {
                    reported = true
                    ready(.success(()))
                }
            case .failed(let error):
                if !reported {
                    reported = true
                    ready(.failure(TransportError.listenFailed(path: endpoint.description, underlying: "\(error)")))
                }
            case .waiting(let error):
                if !reported {
                    reported = true
                    ready(.failure(TransportError.listenFailed(path: endpoint.description, underlying: "\(error)")))
                }
            case .setup, .cancelled:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.onConnection?(connection)
        }
        listener.start(queue: queue)
    }

    public func cancel() {
        let victim = lock.withLock { () -> NWListener? in
            let current = listener
            listener = nil
            return current
        }
        victim?.cancel()
    }
}
