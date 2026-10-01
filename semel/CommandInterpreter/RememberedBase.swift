//
//  RememberedBase.swift
//  semel
//
//  The prompt's base, kept across launches (B-136). `base <path>` writes it and
//  `base --forget` removes it; `semel` starts from it when it names a directory that is
//  still there. A person works on a tree somewhere other than where the terminal opens, and
//  typing the base at every launch was the price of the base lasting one session only.
//
//  Here rather than in SemelNodeKit beside `SemelPaths`, because only the prompt reads it:
//  `semelserv` never sees a disk path it was not pushed, `semel-watch` takes its base as an
//  argument, and `semel-swift prepare` takes a folder. A type every plugin can import would
//  invite one of them to start from a base a person set for another purpose. The log
//  path `ServerLauncher` keeps beside the graph is the same kind of file, and lives here too.
//

import Foundation
import SemelNodeKit

/// The directory a `semel` launch starts from, as `semel.base` in the Semel home holds it.
///
/// A one-key text file in the `key value` form a dependency lock uses: a heading comment
/// saying what the file is, then `base` and the absolute path. Text, so a person who finds
/// it in the home can read it and fix it by hand; strict, so a hand edit that says
/// something else is refused by name rather than read as a directory nobody meant.
public struct RememberedBase: Equatable {

    /// The directory, absolute.
    public let directory: String

    /// Refuses what the file could not hold or a launch could not start from: a relative
    /// path, which would be relative to wherever the next `semel` happens to start, and a
    /// path with a line break, which the file would read back as two lines.
    public init(directory: String) throws {
        guard directory.hasPrefix("/") else {
            throw RememberedBaseError.notAbsolute(directory)
        }
        guard !directory.contains(where: \.isNewline) else {
            throw RememberedBaseError.lineBreakInPath(directory)
        }
        self.directory = directory
    }

    // MARK: - Where it lives

    /// Named as `semelserv.sock` and `semelserv.log` are, for the program whose file it
    /// is: the prompt's, beside the server's.
    public static let fileName = "semel.base"

    /// `semel.base` in the Semel home — `SEMEL_HOME` when set, so a test's file is its own.
    public static var file: URL {
        SemelPaths.root.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - The text

    enum Key: String, CaseIterable {
        case base
    }

    /// The first line of the file, for whoever opens it without knowing what it is.
    static let heading = "# Semel's remembered base: the directory `semel` starts in. "
                       + "`base <path>` writes it, `base --forget` removes it."

    /// The file as it is written: the heading, then the one `key value` line.
    public var text: String {
        "\(Self.heading)\n\(Key.base.rawValue)  \(directory)\n"
    }

    /// Reads the file's text back.
    ///
    /// A `#` line and a blank line are free, as in a lock; anything else is the one key or
    /// a refusal naming its line. The value is the rest of the line after the spaces that
    /// follow the key, kept as it is, trailing spaces and all: a directory may end in one,
    /// and a reader that trimmed it would start somewhere else.
    public static func parse(_ text: String) throws -> RememberedBase {
        var values: [Key: String] = [:]
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }
            let lineNumber = index + 1
            let line       = rawLine.drop { $0.isWhitespace }
            let keyText    = String(line.prefix { !$0.isWhitespace })
            let value      = String(line.dropFirst(keyText.count).drop { $0 == " " || $0 == "\t" })
            guard let key = Key(rawValue: keyText) else {
                throw RememberedBaseError.unknownKey(keyText, line: lineNumber)
            }
            guard values[key] == nil else {
                throw RememberedBaseError.repeatedKey(keyText, line: lineNumber)
            }
            guard !value.isEmpty else {
                throw RememberedBaseError.emptyValue(keyText, line: lineNumber)
            }
            values[key] = value
        }
        guard let directory = values[.base] else {
            throw RememberedBaseError.missingKey(Key.base.rawValue)
        }
        return try RememberedBase(directory: directory)
    }

    // MARK: - On disk

    /// The remembered base in `file`, or nil when there is no file. A file that is there
    /// and cannot be read, or says something other than one base, is an error: the launch
    /// reports it rather than starting from the current directory without a word.
    public static func read(from file: URL) throws -> RememberedBase? {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw RememberedBaseError.unreadable(reason: error.localizedDescription)
        }
        return try parse(text)
    }

    /// Writes the file, making the home first when no server has made it yet. Atomic, so a
    /// launch never reads half of one.
    public func write(to file: URL) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            throw RememberedBaseError.unwritable(file.path, reason: error.localizedDescription)
        }
    }

    /// Removes the file. Returns whether there was one, so `base --forget` can say which.
    public static func forget(at file: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            throw RememberedBaseError.unremovable(file.path, reason: error.localizedDescription)
        }
        return true
    }
}

/// Why the remembered base could not be read, written or removed.
public enum RememberedBaseError: Error, Equatable, CustomStringConvertible {
    case unknownKey(String, line: Int)
    case repeatedKey(String, line: Int)
    case emptyValue(String, line: Int)
    case missingKey(String)
    case notAbsolute(String)
    case lineBreakInPath(String)
    /// The file is there and could not be read as UTF-8 text.
    case unreadable(reason: String)
    case unwritable(String, reason: String)
    case unremovable(String, reason: String)

    public var description: String {
        let keys = RememberedBase.Key.allCases.map(\.rawValue).joined(separator: ", ")
        switch self {
        case .unknownKey(let key, let line):
            return "line \(line): '\(key)' is not a key of the remembered base; the keys are \(keys)"
        case .repeatedKey(let key, let line):
            return "line \(line): '\(key)' is said a second time"
        case .emptyValue(let key, let line):
            return "line \(line): '\(key)' has no value"
        case .missingKey(let key):
            return "there is no '\(key)' line"
        case .notAbsolute(let path):
            return "'\(path)' is not an absolute path"
        case .lineBreakInPath(let path):
            return "'\(path)' holds a line break, which the file cannot hold"
        case .unreadable(let reason):
            return "it could not be read: \(reason)"
        case .unwritable(let path, let reason):
            return "\(path) could not be written: \(reason)"
        case .unremovable(let path, let reason):
            return "\(path) could not be removed: \(reason)"
        }
    }
}

// MARK: - At launch

/// The base a launch starts from, where it came from, and — when a remembered base was
/// there and could not be used — why. What `semel`'s banner prints, decided here without a
/// process so that each case is a test.
public struct LaunchBase: Equatable {

    public enum Origin: Equatable {
        case remembered
        case currentDirectory
    }

    /// Why a remembered base was passed over. The file is left as it is in both cases: a
    /// directory on a volume not mounted yet is back at the next launch, and a hand edit
    /// gone wrong is the person's to see and mend.
    public enum PassedOver: Equatable {
        case directoryGone(String)
        /// The file, and what was wrong with it.
        case unreadable(file: String, RememberedBaseError)
    }

    public let directory: String
    public let origin: Origin
    public let passedOver: PassedOver?

    /// `saved` is what reading `file` gave: nil when there is none. `isDirectory` is the
    /// disk's answer for a path, asked only of a remembered one.
    public static func choose(saved: Result<RememberedBase?, RememberedBaseError>,
                              file: String,
                              isDirectory: (String) -> Bool,
                              currentDirectory: String) -> LaunchBase {
        switch saved {
        case .success(.none):
            return LaunchBase(directory: currentDirectory, origin: .currentDirectory, passedOver: nil)
        case .success(.some(let remembered)):
            guard isDirectory(remembered.directory) else {
                return LaunchBase(directory: currentDirectory, origin: .currentDirectory,
                                  passedOver: .directoryGone(remembered.directory))
            }
            return LaunchBase(directory: remembered.directory, origin: .remembered, passedOver: nil)
        case .failure(let error):
            return LaunchBase(directory: currentDirectory, origin: .currentDirectory,
                              passedOver: .unreadable(file: file, error))
        }
    }

    /// Reads `file` and asks the disk: what `semel` calls at launch.
    public static func atLaunch(file: URL = RememberedBase.file,
                                currentDirectory: String = FileManager.default.currentDirectoryPath) -> LaunchBase {
        let saved: Result<RememberedBase?, RememberedBaseError>
        do {
            saved = .success(try RememberedBase.read(from: file))
        } catch let error as RememberedBaseError {
            saved = .failure(error)
        } catch {
            saved = .failure(.unreadable(reason: error.localizedDescription))
        }
        return choose(saved: saved, file: file.path, isDirectory: isFolder, currentDirectory: currentDirectory)
    }

    static func isFolder(_ path: String) -> Bool {
        var directoryFlag: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directoryFlag) && directoryFlag.boolValue
    }

    /// The banner's lines about the base, after `Graph:`: a passed-over remembered base on
    /// one line of its own, then where this session starts.
    public var bannerLines: [String] {
        var lines: [String] = []
        switch passedOver {
        case .directoryGone(let missing):
            lines.append("Remembered base \(missing) no longer exists; starting from the current directory "
                       + "(`base --forget` stops remembering it).")
        case .unreadable(let file, let error):
            lines.append("Remembered base in \(file) not read, starting from the current directory: \(error)")
        case nil:
            break
        }
        switch origin {
        case .remembered:
            lines.append("Base: \(directory) (remembered)")
        case .currentDirectory:
            lines.append("Base: \(directory)")
        }
        return lines
    }
}
