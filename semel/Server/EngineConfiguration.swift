// EngineConfiguration.swift
// SemelServer
//
// The engine's own settings, kept across launches in `semel.engine.config` in the Semel home,
// beside `semel.base`. `semelserv` reads the file when it starts and writes it when the
// prompt changes a setting (`cache limit <size>`), then applies the change at once.
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

    public init(cacheLimit: ByteCount? = nil) {
        self.cacheLimit = cacheLimit
    }

    // MARK: - Where it lives

    public static let fileName = "semel.engine.config"

    /// `semel.engine.config` in the Semel home — `SEMEL_HOME` when set, so a test's file is
    /// its own.
    public static var file: URL {
        SemelPaths.root.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - The text

    /// Named under `cache.` as the settings that come with a remote cache will be
    /// (`cache.server`, `cache.identity`), so that `cache` at the prompt is where all of
    /// them are seen.
    enum Key: String, CaseIterable {
        case cacheLimit = "cache.limit"
    }

    /// The first lines of the file, for whoever opens it without knowing what it is.
    static let heading = """
        # Semel's engine settings: read by semelserv when it starts. None of them enters a build's
        # input or a cache key. `cache limit <size>` at the prompt writes cache.limit.
        """

    /// The file as it is written: the heading, then a line per setting that is set. A size
    /// is written in its exact form, so it reads back as the same bytes.
    public var text: String {
        var lines = [Self.heading]
        if let cacheLimit {
            lines.append("\(Key.cacheLimit.rawValue)  \(cacheLimit.exactText)")
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
        return configuration
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
        case .unreadable(let path, let reason):
            return "\(path) could not be read: \(reason)"
        case .unwritable(let path, let reason):
            return "\(path) could not be written: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}
