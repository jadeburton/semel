// CacheCommand.swift
// SemelCacheServer
//
// `semel-cache`'s command line, read into a typed command where it is typed: the verb, the
// home, and each argument as the value it names — an address, a size, who may write, a key.

import Foundation
import SemelCache
import SemelNodeKit
import SemelProtocol

public enum CachePurgeTarget: Equatable {
    case key(CacheKey)
    case all
}

public enum CacheCommand: Equatable {
    /// Runs the server. `settings` are the ones the arguments name; the rest come from the
    /// home's file.
    case serve(home: CacheHome, settings: CacheServerConfiguration)
    case status(home: CacheHome)
    case purge(home: CacheHome, target: CachePurgeTarget)
    case help

    public static let usage = """
        usage: semel-cache serve  --home <folder> [--listen <host:port>] [--limit <size>] [--writers all|none]
               semel-cache status --home <folder>
               semel-cache purge  --home <folder> <key> | --all

        serve   runs the shared cache over TCP. The settings given are written to
                semel.cache.config in the home and read from it at every start, so a later
                `serve --home <folder>` starts as this one did. --limit is the size of the
                objects the entries may hold (default 10G); --writers says whether clients
                that ask to write may (default none: every client reads only).
        status  prints the entries, the bytes they hold against the limit, and — from a
                running server — its hits and misses since it started.
        purge   removes one entry by its key, or every entry and every object. Through the
                running server when there is one; on the home itself when there is none.
        """

    /// The command `arguments` — everything after the program's name — say.
    public static func parse(_ arguments: [String]) throws -> CacheCommand {
        guard let verb = arguments.first else {
            throw CacheCommandError.noVerb
        }
        var remaining = Array(arguments.dropFirst())
        switch verb {
        case "-h", "--help", "help":
            return .help
        case "serve":
            let home = try takeHome(from: &remaining)
            var settings = CacheServerConfiguration()
            while let flag = remaining.first {
                remaining.removeFirst()
                let value = try takeValue(of: flag, from: &remaining)
                switch flag {
                case "--listen":
                    guard let address = CacheAddress(parsing: value) else {
                        throw CacheCommandError.notAnAddress(value)
                    }
                    settings.listen = address
                case "--limit":
                    guard let limit = ByteCount(parsing: value) else {
                        throw CacheCommandError.notASize(value)
                    }
                    settings.limit = limit
                case "--writers":
                    guard let writers = CacheWriters(rawValue: value) else {
                        throw CacheCommandError.notWriters(value)
                    }
                    settings.writers = writers
                default:
                    throw CacheCommandError.unknownArgument(flag, verb: verb)
                }
            }
            return .serve(home: home, settings: settings)
        case "status":
            let home = try takeHome(from: &remaining)
            guard remaining.isEmpty else {
                throw CacheCommandError.unknownArgument(remaining[0], verb: verb)
            }
            return .status(home: home)
        case "purge":
            let home = try takeHome(from: &remaining)
            guard remaining.count == 1 else {
                throw CacheCommandError.purgeNeedsOneTarget
            }
            if remaining[0] == "--all" {
                return .purge(home: home, target: .all)
            }
            guard let key = CacheKey(parsing: remaining[0]) else {
                throw CacheCommandError.notAKey(remaining[0])
            }
            return .purge(home: home, target: .key(key))
        default:
            throw CacheCommandError.unknownVerb(verb)
        }
    }

    /// `--home <folder>`, wherever it stands among the arguments, taken out of them.
    private static func takeHome(from arguments: inout [String]) throws -> CacheHome {
        guard let index = arguments.firstIndex(of: "--home") else {
            throw CacheCommandError.noHome
        }
        guard index + 1 < arguments.count else {
            throw CacheCommandError.missingValue("--home")
        }
        let path = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return CacheHome(folder: URL(fileURLWithPath: path, isDirectory: true))
    }

    private static func takeValue(of flag: String, from arguments: inout [String]) throws -> String {
        guard flag.hasPrefix("--") else {
            throw CacheCommandError.unknownArgument(flag, verb: "serve")
        }
        guard let value = arguments.first else {
            throw CacheCommandError.missingValue(flag)
        }
        arguments.removeFirst()
        return value
    }
}

public enum CacheCommandError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case noVerb
    case unknownVerb(String)
    case noHome
    case missingValue(String)
    case unknownArgument(String, verb: String)
    case notAnAddress(String)
    case notASize(String)
    case notWriters(String)
    case notAKey(String)
    case purgeNeedsOneTarget

    public var description: String {
        switch self {
        case .noVerb:
            return "say what to do: serve, status or purge"
        case .unknownVerb(let verb):
            return "'\(verb)' is not something semel-cache does; it does serve, status and purge"
        case .noHome:
            return "--home <folder> is required: the folder the cache keeps everything in"
        case .missingValue(let flag):
            return "\(flag) needs a value"
        case .unknownArgument(let argument, let verb):
            return "'\(argument)' is not an argument of \(verb)"
        case .notAnAddress(let value):
            return "'\(value)' is not a host and port for --listen; give one as 127.0.0.1:7070"
        case .notASize(let value):
            return "'\(value)' is not a size for --limit; give bytes, or a number with K, M or G after it — 512M, 20G"
        case .notWriters(let value):
            return "'\(value)' is not who may write; --writers is all or none"
        case .notAKey(let value):
            return "'\(value)' is not a cache key, which is 64 hex digits"
        case .purgeNeedsOneTarget:
            return "purge takes one key, or --all"
        }
    }

    public var errorDescription: String? { description }
}
