// Endpoint.swift
// SemelTransport
//
// Where a connection goes and a listener listens: a Unix-domain socket in the file system,
// which is how a client reaches the engine on its own machine, or a TCP port, which is how
// an engine will reach a cache on another. NWConnection and NWListener carry frames over
// either the same way, so nothing above this type knows which it has.

import Foundation
import Network

public enum Endpoint: Equatable, Hashable, CustomStringConvertible {

    /// A socket file. Its path is the address, and the directory it lies in is what stands
    /// in for authentication.
    case unix(path: String)

    /// A host and a port. Port 0 asks a listener for any free port, which it then reports
    /// (`SocketListener.port`); a connection always names the port it wants.
    case tcp(host: String, port: UInt16)

    /// The path or `host:port`, as a message names where something could not be reached.
    public var description: String {
        switch self {
        case .unix(let path):
            return path
        case .tcp(let host, let port):
            return "\(host):\(port)"
        }
    }

    /// Refuses an address Network.framework would trap on rather than fail: a socket path
    /// over the kernel's limit (`UnixSocketPath`).
    public func check() throws {
        switch self {
        case .unix(let path):
            try UnixSocketPath.check(path)
        case .tcp:
            break
        }
    }

    /// For a connection.
    var networkEndpoint: NWEndpoint {
        switch self {
        case .unix(let path):
            return .unix(path: path)
        case .tcp(let host, let port):
            return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        }
    }

    /// For a listener: what it binds to. Frames are a byte stream, so both are TCP's
    /// parameters; a Unix socket is a stream socket with a path for its address.
    var listenerParameters: NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = networkEndpoint
        return parameters
    }
}
