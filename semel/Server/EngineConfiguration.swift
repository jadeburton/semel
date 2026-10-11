// EngineConfiguration.swift
// SemelServer
//
// The engine's own settings, kept across launches in `semel.engine.config` in the Semel home,
// beside `semel.base`. `semelserv` reads the file when it starts and writes it when the
// prompt changes a setting (`cache limit <size>`, `cache server <host:port>`, `cache
// identity <name>`), then applies the change at once.
//
// None of these settings may affect what a build produces, so none of them enters `input:`
// and none enters a cache key. That is why they have a file of their own: the machine file
// (`semel.machine.config`) is pushed into `input:` and read by nodes through config
// filters, and `semel.config` is read the same way, so a setting put in either would wake
// nodes, move keys and spoil every entry a change of it touched. Here rather than in
// SemelNodeKit beside `SemelPaths`, because only the server reads and writes it: a type
// every plugin can import would invite one of them to read a setting no build may depend on.

import Foundation
import SemelNodeKit
import SemelProtocol

/// What `semel.engine.config` holds.
///
/// A text file in the `key value` form the home's other files use (`RememberedBase`): a
/// heading comment saying what the file is, then one line per setting that is set. Text, so
/// a person who finds it in the home can read and mend it; strict, so a hand edit that says
/// something else is refused by name, and `semelserv` will not start over a setting it
/// cannot read rather than start without a word under a different one.
public struct EngineConfiguration: Equatable {

    /// The cache's limit (B-148), nil when the home sets none and the engine's default
    /// applies.
    public var cacheLimit: ByteCount?

    /// The shared cache the engine reads from and writes to (B-153), nil when the home names
    /// none and the engine is its local cache alone.
    public var cacheServer: CacheAddress?

    /// The name the engine gives the shared cache in its hello, nil for none.
    public var cacheIdentity: String?

    public init(cacheLimit: ByteCount? = nil, cacheServer: CacheAddress? = nil, cacheIdentity: String? = nil) {
        self.cacheLimit    = cacheLimit
        self.cacheServer   = cacheServer
        self.cacheIdentity = cacheIdentity
    }

    // MARK: - Where it lives

    public static let fileName = "semel.engine.config"

    /// `semel.engine.config` in the Semel home — `SEMEL_HOME` when set, so a test's file is
    /// its own.
    public static var file: URL {
        SemelPaths.root.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - The text

    /// Named under `cache.`, so that `cache` at the prompt is where all of them are seen.
    enum Key: String, CaseIterable {
        case cacheLimit    = "cache.limit"
        case cacheServer   = "cache.server"
        case cacheIdentity = "cache.identity"
    }

    /// The first lines of the file, for whoever opens it without knowing what it is.
    static let heading = """
        # Semel's engine settings: read by semelserv when it starts. None of them enters a build's
        # input or a cache key. `cache limit <size>`, `cache server <host:port>` and
        # `cache identity <name>` at the prompt write cache.limit, cache.server and cache.identity.
        """

    /// The file as it is written: the heading, then a line per setting that is set. A size
    /// is written in its exact form, so it reads back as the same bytes.
    public var text: String {
        var lines = [Self.heading]
        if let cacheLimit {
            lines.append("\(Key.cacheLimit.rawValue)     \(cacheLimit.exactText)")
        }
        if let cacheServer {
            lines.append("\(Key.cacheServer.rawValue)    \(cacheServer)")
        }
        if let cacheIdentity {
            lines.append("\(Key.cacheIdentity.rawValue)  \(cacheIdentity)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads the file's text back. A `#` line and a blank line are free; anything else is a
    /// key this file holds, said once, with a value of its kind, or a refusal naming its
    /// line.
    public static func parse(_ text: String) throws -> EngineConfiguration {
        var values: [Key: (value: String, line: Int)] = [:]
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }
            let lineNumber = index + 1
            let keyText    = String(trimmed.prefix { !$0.isWhitespace })
            let value      = trimmed.dropFirst(keyText.count).trimmingCharacters(in: .whitespaces)
            guard let key = Key(rawValue: keyText) else {
                throw EngineConfigurationError.unknownKey(keyText, line: lineNumber)
            }
            guard values[key] == nil else {
                throw EngineConfigurationError.repeatedKey(keyText, line: lineNumber)
            }
            guard !value.isEmpty else {
                throw EngineConfigurationError.emptyValue(keyText, line: lineNumber)
            }
            values[key] = (value, lineNumber)
        }
        var configuration = EngineConfiguration()
        if let (value, line) = values[.cacheLimit] {
            guard let limit = ByteCount(parsing: value) else {
                throw EngineConfigurationError.notASize(Key.cacheLimit.rawValue, value, line: line)
            }
            configuration.cacheLimit = limit
        }
        if let (value, line) = values[.cacheServer] {
            guard let address = CacheAddress(parsing: value) else {
                throw EngineConfigurationError.notAnAddress(Key.cacheServer.rawValue, value, line: line)
            }
            configuration.cacheServer = address
        }
        if let (value, line) = values[.cacheIdentity] {
            guard Self.isIdentity(value) else {
                throw EngineConfigurationError.notAnIdentity(Key.cacheIdentity.rawValue, value, line: line)
            }
            configuration.cacheIdentity = value
        }
        return configuration
    }

    /// Whether `text` can be a client's name: one word of printable characters, so that it
    /// is one value on its line and reads back as written.
    public static func isIdentity(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0)
                                                          && !CharacterSet.controlCharacters.contains($0) }
    }

    // MARK: - On disk

    /// The settings in `file`; none set when there is no file, which is a home that never
    /// changed one.
    public static func read(from file: URL) throws -> EngineConfiguration {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return EngineConfiguration()
        }
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw EngineConfigurationError.unreadable(file.path, reason: error.localizedDescription)
        }
        return try parse(text)
    }

    /// Writes the file, making the home first if nothing has. Atomic, so a server starting
    /// meanwhile never reads half of one.
    public func write(to file: URL) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            throw EngineConfigurationError.unwritable(file.path, reason: error.localizedDescription)
        }
    }
}

/// Why `semel.engine.config` could not be read or written.
public enum EngineConfigurationError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unknownKey(String, line: Int)
    case repeatedKey(String, line: Int)
    case emptyValue(String, line: Int)
    case notASize(String, String, line: Int)
    case notAnAddress(String, String, line: Int)
    case notAnIdentity(String, String, line: Int)
    /// The file is there and could not be read as UTF-8 text.
    case unreadable(String, reason: String)
    case unwritable(String, reason: String)

    public var description: String {
        let keys = EngineConfiguration.Key.allCases.map(\.rawValue).joined(separator: ", ")
        switch self {
        case .unknownKey(let key, let line):
            return "line \(line): '\(key)' is not a setting of the engine; the settings are \(keys)"
        case .repeatedKey(let key, let line):
            return "line \(line): '\(key)' is said a second time"
        case .emptyValue(let key, let line):
            return "line \(line): '\(key)' has no value"
        case .notASize(let key, let value, let line):
            return "line \(line): '\(value)' is not a size for '\(key)'; give bytes, or a number with K, M or G after it"
        case .notAnAddress(let key, let value, let line):
            return "line \(line): '\(value)' is not an address for '\(key)'; give a host and a port, as 192.168.1.20:7070"
        case .notAnIdentity(let key, let value, let line):
            return "line \(line): '\(value)' is not a name for '\(key)'; give one word"
        case .unreadable(let path, let reason):
            return "\(path) could not be read: \(reason)"
        case .unwritable(let path, let reason):
            return "\(path) could not be written: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}
