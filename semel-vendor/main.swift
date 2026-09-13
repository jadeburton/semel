//
//  main.swift
//  semel-vendor
//
//  semel-vendor <package-root>
//  semel-vendor --into <dependencies-folder> <package-root>...
//  semel-vendor init <folder> [--platform macos|ios-simulator]
//
//  The Swift conversion tool, outside Semel. The first two forms resolve each package's
//  dependencies with SwiftPM and copy every checkout into the Dependencies folder — the
//  package's own by default, or the one `--into` names when a formula includes several
//  packages under one build root (`SwiftFormulaConverter(path: <pkg>, root: <.>)`), so
//  their common closure is vendored once. Run it before pushing the tree; run it again
//  after changing a dependency.
//
//  `init` is the whole conversion for a tree of packages: finds them, vendors the roots'
//  closure into `<folder>/Dependencies`, and writes `semel.fmla` and `semel.config` beside
//  them unless they are already there. After it, `semel 'base <folder>/..' 'build <folder>'`.

import Foundation
import SemelVendor

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: semel-vendor <package-root>
               semel-vendor --into <dependencies-folder> <package-root>...
               semel-vendor init <folder> [--platform \(Platform.allCases.map(\.rawValue).joined(separator: "|"))]

        """.utf8))
    exit(64) // EX_USAGE
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("semel-vendor: \(error)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())

// MARK: - init

if arguments.first == "init" {
    arguments.removeFirst()
    var platform = Platform.macos
    if let flag = arguments.firstIndex(of: "--platform") {
        guard flag + 1 < arguments.count, let chosen = Platform(rawValue: arguments[flag + 1]) else {
            usage()
        }
        platform = chosen
        arguments.removeSubrange(flag...(flag + 1))
    }
    guard arguments.count == 1 else {
        usage()
    }
    let folder = URL(fileURLWithPath: arguments[0], isDirectory: true)

    do {
        let report = try Initialization.run(folder: folder, platform: platform)
        print("Roots:")
        for root in report.roots {
            print("  \(root.name) (\(root.folder.path))")
        }
        if report.vendored.isEmpty {
            print("No dependencies to vendor.")
        }
        for entry in report.vendored {
            print("\(entry.name) -> \(entry.destination.path)")
        }
        for file in report.written {
            print("Written: \(file.path)")
        }
        for file in report.kept {
            print("Kept as it is: \(file.path)")
        }
    } catch {
        fail(error)
    }
    exit(0)
}

// MARK: - vendor

var destination: URL?

if let flag = arguments.firstIndex(of: "--into") {
    guard flag + 1 < arguments.count else { usage() }
    destination = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    arguments.removeSubrange(flag...(flag + 1))
}

guard !arguments.isEmpty, destination != nil || arguments.count == 1 else {
    usage()
}

let packageRoots = arguments.map { URL(fileURLWithPath: $0, isDirectory: true) }

do {
    let copied: [Vendoring.Copied]
    if let destination {
        copied = try Vendoring.vendor(packageRoots: packageRoots, into: destination)
    } else {
        copied = try Vendoring.vendor(packageRoot: packageRoots[0])
    }
    if copied.isEmpty {
        print("No dependencies to vendor.")
    }
    for entry in copied {
        print("\(entry.name) -> \(entry.destination.path)")
    }
} catch {
    fail(error)
}
