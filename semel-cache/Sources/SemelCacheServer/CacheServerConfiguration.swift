// CacheServerConfiguration.swift
// SemelCacheServer
//
// A cache server's settings, kept across launches in `semel.cache.config` in its home:
// where it listens, how large its store may grow, and who may write. `semel-cache serve`
// writes the arguments it was given into the file and then reads the file, so a server
// started again with `--home` alone starts as it last did.
//
// The same invariant as the engine's `semel.engine.config`: none of these settings may
// change what an entry holds or the key it is filed under. They decide where the cache
// answers, how much it keeps and whom it lets write — what it has, never what anything in
// it means — which is why they live in a file of the server's and never travel with an
// entry.

import Foundation
import SemelNodeKit

/// Who may write: everyone who asks, or nobody. A list of identities comes when a deployment
/// needs one, as a change here and not to the protocol (the 2026-10-11 design).
public enum CacheWriters: String, CaseIterable, Equatable, Sendable {
    case all
    case none
}

/// A host and a port, as `--listen` and the file write one: `127.0.0.1:7070`, `[::1]:7070`.
public struct CacheListenAddress: Equatable, Sendable, CustomStringConvertible {
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

/// What `semel.cache.config` holds: each setting the file names, nil where it names none.
public struct CacheServerConfiguration: Equatable {

    public var listen: CacheListenAddress?
    public var limit: ByteCount?
    public var writers: CacheWriters?

    public init(listen: CacheListenAddress? = nil, limit: ByteCount? = nil, writers: CacheWriters? = nil) {
        self.listen  = listen
        self.limit   = limit
        self.writers = writers
    }

    /// The limit of a store whose file sets none: the engine's default, so a cache server
    /// started without one holds what one developer's home would.
    public static let defaultLimit = ByteCount.gibibytes(10)

    /// Read-only unless said otherwise: anyone who can write to a shared cache can poison
    /// every reader of it.
    public static let defaultWriters = CacheWriters.none

    /// These settings with every one `other` names put over them: what the arguments of a
    /// `serve` make of the file.
    public func overridden(by other: CacheServerConfiguration) -> CacheServerConfiguration {
        CacheServerConfiguration(listen: other.listen ?? listen,
                                 limit: other.limit ?? limit,
                                 writers: other.writers ?? writers)
    }

    // MARK: - The text

    enum Key: String, CaseIterable {
        case listen
        case limit
        case writers
    }

    static let heading = """
        # semel-cache's settings: read by `semel-cache serve` when it starts, and written by the
        # arguments it is given. None of them changes what an entry holds or the key it is under.
        """

    /// The heading, then a line per setting that is set, in a fixed order. A size in its
    /// exact form, so it reads back as the same bytes.
    public var text: String {
        var lines = [Self.heading]
        if let listen {
            lines.append("\(Key.listen.rawValue)   \(listen)")
        }
        if let limit {
            lines.append("\(Key.limit.rawValue)    \(limit.exactText)")
        }
        if let writers {
            lines.append("\(Key.writers.rawValue)  \(writers.rawValue)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The file's text read back. A `#` line and a blank line are free; anything else is a
    /// setting of this file, said once, with a value of its kind, or a refusal naming its
    /// line — strict, as the engine's file is, so a hand edit that says something else stops
    /// the server rather than starts it on a setting nobody chose.
    public static func parse(_ text: String) throws -> CacheServerConfiguration {
        var configuration = CacheServerConfiguration()
        var seen: Set<Key> = []
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }
            let line    = index + 1
            let keyText = String(trimmed.prefix { !$0.isWhitespace })
            let value   = trimmed.dropFirst(keyText.count).trimmingCharacters(in: .whitespaces)
            guard let key = Key(rawValue: keyText) else {
                throw CacheServerConfigurationError.unknownKey(keyText, line: line)
            }
            guard seen.insert(key).inserted else {
                throw CacheServerConfigurationError.repeatedKey(keyText, line: line)
            }
            guard !value.isEmpty else {
                throw CacheServerConfigurationError.emptyValue(keyText, line: line)
            }
            switch key {
            case .listen:
                guard let address = CacheListenAddress(parsing: value) else {
                    throw CacheServerConfigurationError.notAnAddress(value, line: line)
                }
                configuration.listen = address
            case .limit:
                guard let limit = ByteCount(parsing: value) else {
                    throw CacheServerConfigurationError.notASize(value, line: line)
                }
                configuration.limit = limit
            case .writers:
                guard let writers = CacheWriters(rawValue: value) else {
                    throw CacheServerConfigurationError.notWriters(value, line: line)
                }
                configuration.writers = writers
            }
        }
        return configuration
    }

    // MARK: - On disk

    /// The settings in `file`; none when there is no file.
    public static func read(from file: URL) throws -> CacheServerConfiguration {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return CacheServerConfiguration()
        }
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw CacheServerConfigurationError.unreadable(file.path, reason: error.localizedDescription)
        }
        do {
            return try parse(text)
        } catch let error as CacheServerConfigurationError {
            throw CacheServerConfigurationError.inFile(file.path, error.description)
        }
    }

    /// Writes the file, atomically, so a server starting meanwhile never reads half of one.
    public func write(to file: URL) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            throw CacheServerConfigurationError.unwritable(file.path, reason: error.localizedDescription)
        }
    }
}

/// Why `semel.cache.config` could not be read or written.
public enum CacheServerConfigurationError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unknownKey(String, line: Int)
    case repeatedKey(String, line: Int)
    case emptyValue(String, line: Int)
    case notAnAddress(String, line: Int)
    case notASize(String, line: Int)
    case notWriters(String, line: Int)
    case unreadable(String, reason: String)
    case unwritable(String, reason: String)
    /// One of the above, in the file at the path.
    case inFile(String, String)

    public var description: String {
        let keys = CacheServerConfiguration.Key.allCases.map(\.rawValue).joined(separator: ", ")
        switch self {
        case .unknownKey(let key, let line):
            return "line \(line): '\(key)' is not a setting of semel-cache; the settings are \(keys)"
        case .repeatedKey(let key, let line):
            return "line \(line): '\(key)' is said a second time"
        case .emptyValue(let key, let line):
            return "line \(line): '\(key)' has no value"
        case .notAnAddress(let value, let line):
            return "line \(line): '\(value)' is not a host and port for 'listen'; give one as 127.0.0.1:7070"
        case .notASize(let value, let line):
            return "line \(line): '\(value)' is not a size for 'limit'; give bytes, or a number with K, M or G after it"
        case .notWriters(let value, let line):
            return "line \(line): '\(value)' is not who may write; 'writers' is all or none"
        case .unreadable(let path, let reason):
            return "\(path) could not be read: \(reason)"
        case .unwritable(let path, let reason):
            return "\(path) could not be written: \(reason)"
        case .inFile(let path, let problem):
            return "\(path): \(problem)"
        }
    }

    public var errorDescription: String? { description }
}
