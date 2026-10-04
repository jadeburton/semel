// WatchConfiguration.swift
// SemelWatch
//
// What one `semel-watch` was asked to do, read from its arguments (B-126):
//
//     semel-watch <base> [<folder> ...] [--only <pattern>]... [--except <pattern>]...
//                 [--into <dir>] [--settle-after <ms>] [--no-initial] [--no-reports]

import Foundation
import SemelNodeKit

public struct WatchConfiguration: Equatable {

    /// What `--settle-after` is when it is not given. Two seconds rather than the few
    /// hundred milliseconds a debounce usually takes: a save that lands mid-checkout, or a
    /// format-on-save rewriting the file just saved, is one batch and one settle instead
    /// of two, and a person who has just saved is reading the editor, not the summary.
    public static let defaultQuietInterval = Duration.seconds(2)

    /// The directory `push` reads from, absolute, links resolved.
    public var base: String
    /// The folders watched and pushed, relative to `base`; the empty path is `base` itself.
    public var folders: [Path]
    public var only: [String]
    public var except: [String]
    /// Where each settle without errors is exported, absolute; nil exports nothing.
    public var exportDestination: String?
    public var quietInterval: Duration
    /// Whether the initial batch mirrors every watched folder before the first change:
    /// removes what the graph holds and the disk lacks, then pushes. `--no-initial` is false.
    public var pushesInitially: Bool
    /// Whether this watcher prints the settle summary, the artifact diff and the error
    /// report. Off when the prompt started it: the prompt prints them from its own
    /// subscription, and two clients printing one settle into one terminal print it twice.
    public var printsReports: Bool

    public init(base: String, folders: [Path] = [.empty], only: [String] = [], except: [String] = [],
                exportDestination: String? = nil, quietInterval: Duration = defaultQuietInterval,
                pushesInitially: Bool = true, printsReports: Bool = true) {
        self.base              = base
        self.folders           = folders
        self.only              = only
        self.except            = except
        self.exportDestination = exportDestination
        self.quietInterval     = quietInterval
        self.pushesInitially   = pushesInitially
        self.printsReports     = printsReports
    }

    /// The filter these arguments describe.
    public var filter: WatchFilter {
        WatchFilter(roots: folders, only: only, except: except,
                    exportDestination: exportDestination
                        .flatMap { Self.relativePath(of: $0, under: base) }
                        .map { Path($0) })
    }

    // MARK: - Reading the arguments

    public static let usage = """
        usage: semel-watch <base> [<folder> ...] [--only <pattern>]... [--except <pattern>]...
                           [--into <dir>] [--settle-after <ms>] [--no-initial] [--no-reports]
        """

    /// Reads the arguments after the program's name. Relative paths are read from
    /// `currentDirectory`: the base and `--into` as a shell gives them, each folder from the
    /// base, as `push` reads its argument.
    public static func parse(_ arguments: [String], currentDirectory: String) throws -> WatchConfiguration {
        var positional: [String] = []
        var only: [String] = []
        var except: [String] = []
        var destination: String?
        var quietInterval = defaultQuietInterval
        var pushesInitially = true
        var printsReports = true

        var index = 0
        func value(of flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw WatchArgumentError.missingValue(flag: flag)
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--only":         only.append(try value(of: argument))
            case "--except":       except.append(try value(of: argument))
            case "--into":         destination = try value(of: argument)
            case "--settle-after":
                let text = try value(of: argument)
                guard let milliseconds = Int(text), milliseconds > 0 else {
                    throw WatchArgumentError.notMilliseconds(text)
                }
                quietInterval = .milliseconds(milliseconds)
            case "--no-initial":   pushesInitially = false
            case "--no-reports":   printsReports = false
            default:
                guard !argument.hasPrefix("--") else {
                    throw WatchArgumentError.unknownOption(argument)
                }
                positional.append(argument)
            }
            index += 1
        }

        guard let baseArgument = positional.first else {
            throw WatchArgumentError.missingBase
        }
        let base = absolute(baseArgument, from: currentDirectory)
        guard isFolder(base) else {
            throw WatchArgumentError.notAFolder(baseArgument)
        }

        var folders: [Path] = []
        for folderArgument in positional.dropFirst() {
            let folder = absolute(folderArgument, from: base)
            guard folder == base || relativePath(of: folder, under: base) != nil else {
                throw WatchArgumentError.outsideBase(folder: folderArgument, base: base)
            }
            guard isFolder(folder) else {
                throw WatchArgumentError.notAFolder(folderArgument)
            }
            folders.append(Path(relativePath(of: folder, under: base) ?? ""))
        }

        return WatchConfiguration(base:              base,
                                  folders:           folders.isEmpty ? [.empty] : folders,
                                  only:              only,
                                  except:            except,
                                  exportDestination: destination.map { absolute($0, from: currentDirectory) },
                                  quietInterval:     quietInterval,
                                  pushesInitially:   pushesInitially,
                                  printsReports:     printsReports)
    }

    /// `path` made absolute against `directory`, `~` expanded, `.` and `..` folded and
    /// links resolved — so the base is spelled as the disk spells it, and a folder or an
    /// export destination is compared with it in that one spelling.
    static func absolute(_ path: String, from directory: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            expanded = (directory as NSString).appendingPathComponent(expanded)
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// `path` relative to `base` when it lies strictly under it, else nil.
    static func relativePath(of path: String, under base: String) -> String? {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let root     = URL(fileURLWithPath: base).standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved != root, resolved.hasPrefix(root + "/") else {
            return nil
        }
        return String(resolved.dropFirst(root.count + 1))
    }

    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

public enum WatchArgumentError: Error, Equatable, CustomStringConvertible {
    case missingBase
    case missingValue(flag: String)
    case unknownOption(String)
    case notMilliseconds(String)
    case notAFolder(String)
    case outsideBase(folder: String, base: String)

    public var description: String {
        switch self {
        case .missingBase:
            return "no base: the first argument is the directory pushes are read from"
        case .missingValue(let flag):
            return "\(flag) needs a value"
        case .unknownOption(let option):
            return "unknown option \(option)"
        case .notMilliseconds(let text):
            return "--settle-after takes a whole number of milliseconds above zero, not \(text)"
        case .notAFolder(let path):
            return "\(path): no such folder"
        case .outsideBase(let folder, let base):
            return "\(folder) is not under the base \(base); a push reads only from under it"
        }
    }
}
