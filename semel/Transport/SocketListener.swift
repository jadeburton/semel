// SocketListener.swift
// SemelTransport
//
// An NWListener bound to a Unix-domain socket path. The listener creates the socket file
// when it becomes ready and does not remove it when cancelled; the owner does that,
// because only the owner knows whether the file is still its own.

import Foundation
import Network

public final class SocketListener {

    /// Called on `queue` for each accepted connection, not yet started.
    public var onConnection: ((NWConnection) -> Void)?

    public let path: String

    private let queue: DispatchQueue
    private var listener: NWListener?

    public init(path: String, queue: DispatchQueue) {
        self.path  = path
        self.queue = queue
    }

    /// Binds and listens. `ready` is called once, on `queue`, when the socket file exists
    /// and connections are being accepted, or with the error that prevented it.
    public func start(ready: @escaping (Result<Void, Error>) -> Void) {
        do {
            try UnixSocketPath.check(path)
        } catch {
            queue.async { ready(.failure(error)) }
            return
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            queue.async { ready(.failure(TransportError.listenFailed(path: self.path, underlying: "\(error)"))) }
            return
        }
        self.listener = listener

        var reported = false
        listener.stateUpdateHandler = { [path] state in
            switch state {
            case .ready:
                if !reported {
                    reported = true
                    ready(.success(()))
                }
            case .failed(let error):
                if !reported {
                    reported = true
                    ready(.failure(TransportError.listenFailed(path: path, underlying: "\(error)")))
                }
            case .waiting(let error):
                if !reported {
                    reported = true
                    ready(.failure(TransportError.listenFailed(path: path, underlying: "\(error)")))
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
        listener?.cancel()
        listener = nil
    }
}
