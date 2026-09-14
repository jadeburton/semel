// FrameStream.swift
// SemelTransport
//
// Frames over one NWConnection. The read side feeds whatever the socket delivers into a
// FrameDecoder and hands out whole frames; the write side sends encoded frames in the
// order they were given, from one queue, so two frames from one process never interleave
// on the wire. Both ends of a connection use this, which is why it is its own target.

import Foundation
import Network
import SemelProtocol

public enum TransportError: Error, CustomStringConvertible {
    case listenFailed(path: String, underlying: String)
    case connectionFailed(underlying: String)
    case pathTooLong(path: String, length: Int, limit: Int)
    case closed

    public var description: String {
        switch self {
        case .listenFailed(let path, let underlying):
            return "cannot listen at \(path): \(underlying)"
        case .connectionFailed(let underlying):
            return "connection failed: \(underlying)"
        case .pathTooLong(let path, let length, let limit):
            return "socket path is \(length) bytes, over the \(limit)-byte limit: \(path)"
        case .closed:
            return "the connection is closed"
        }
    }
}

extension TransportError: Equatable {}

/// The one rule about socket paths. macOS stores a Unix-domain socket address in a fixed
/// 104-byte field with a terminating zero, and NWConnection traps rather than fails on a
/// longer one, so both sides check before touching Network.framework.
public enum UnixSocketPath {

    public static let maximumLength = 103

    public static func check(_ path: String) throws {
        let length = path.utf8.count
        guard length <= maximumLength else {
            throw TransportError.pathTooLong(path: path, length: length, limit: maximumLength)
        }
    }
}

public final class FrameStream {

    /// Called on `queue` with each complete frame, in arrival order.
    public var onFrame: ((Frame) -> Void)?

    /// Called on `queue` once, when the connection ends: nil for a clean close by the
    /// peer, a `FrameError` for bytes that cannot be framed, a `TransportError` otherwise.
    public var onClose: ((Error?) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var decoder = FrameDecoder()
    private var isClosed = false

    private static let receiveChunk = 1 << 16

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue      = queue
    }

    // MARK: - Lifecycle

    /// Installs the state handler, starts the connection if nobody has, and begins the
    /// receive loop. Call once. A client that waited for `.ready` itself hands over a
    /// started connection; starting it again is not defined, so the state is checked.
    public func start() {
        let needsStart = connection.state == .setup
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.finish(with: TransportError.connectionFailed(underlying: "\(error)"))
            case .waiting(let error):
                // Nothing is listening at the path, or it refused. NWConnection would keep
                // retrying; a client of a local daemon should hear the answer now.
                self?.finish(with: TransportError.connectionFailed(underlying: "\(error)"))
            case .cancelled:
                self?.finish(with: nil)
            case .setup, .preparing, .ready:
                break
            @unknown default:
                break
            }
        }
        if needsStart {
            connection.start(queue: queue)
        }
        receiveNext()
    }

    /// Ends the connection. `onClose` is not called for a close this side asked for.
    public func close() {
        queue.async { [self] in
            isClosed = true
            connection.cancel()
        }
    }

    // MARK: - Sending

    public func send(_ frame: Frame) {
        // Encoding can fail only on an over-limit frame, which is a bug on this side; the
        // stream closes rather than silently dropping the frame.
        do {
            sendRaw(try FrameEncoder.encode(frame))
        } catch {
            finish(with: error)
        }
    }

    /// Bytes as they are, for tests that need to put a malformed frame on the wire.
    func sendRaw(_ bytes: Data) {
        queue.async { [self] in
            guard !isClosed else {
                return
            }
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.finish(with: TransportError.connectionFailed(underlying: "\(error)"))
                }
            })
        }
    }

    // MARK: - Receiving

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunk) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            // A receive completion can land after `close()`; the owner has stopped
            // listening by then and a frame handed over now would reach a torn-down state.
            guard !isClosed else {
                return
            }
            if let data, !data.isEmpty {
                decoder.append(data)
                do {
                    while let frame = try decoder.next() {
                        onFrame?(frame)
                    }
                } catch {
                    finish(with: error)
                    return
                }
            }
            if let error {
                finish(with: TransportError.connectionFailed(underlying: "\(error)"))
                return
            }
            if isComplete {
                finish(with: nil)
                return
            }
            receiveNext()
        }
    }

    /// Runs `onClose` at most once and cancels the connection. Always on `queue`.
    private func finish(with error: Error?) {
        queue.async { [self] in
            guard !isClosed else {
                return
            }
            isClosed = true
            connection.cancel()
            onClose?(error)
        }
    }
}
