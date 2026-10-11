// CacheAddress.swift
// SemelProtocol
//
// Where a shared cache is (B-153): the address `semel-cache serve` listens at and the one an
// engine's home names in `cache.server`.

import Foundation

/// A host and a port, as a cache server's `--listen` and an engine's `cache.server` write
/// one: `127.0.0.1:7070`, `[::1]:7070`. In the protocol because both ends name it — the
/// server where it listens, the engine where it connects, and the prompt in a request that
/// sets it — and one parser is what keeps the two files agreeing about what an address is.
public struct CacheAddress: Codable, Equatable, Sendable, CustomStringConvertible {
    public let host: String
    /// 0 asks for any free port, which the server reports once it listens.
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Nil for anything that is not a host, a colon and a port number.
    public init?(parsing text: String) {
        guard let colon = text.lastIndex(of: ":") else {
            return nil
        }
        var host = String(text[..<colon])
        let portText = text[text.index(after: colon)...]
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty, !host.contains(where: \.isWhitespace),
              !portText.isEmpty, portText.allSatisfy(\.isASCII), let port = UInt16(portText) else {
            return nil
        }
        self.init(host: host, port: port)
    }

    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Where a client on this machine reaches a server listening here: the loopback address
    /// for a server listening on every interface.
    public var localHost: String {
        switch host {
        case "0.0.0.0":
            return "127.0.0.1"
        case "::":
            return "::1"
        default:
            return host
        }
    }
}
