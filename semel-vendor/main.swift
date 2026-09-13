//
//  main.swift
//  semel-vendor
//
//  semel-vendor <package-root>
//  semel-vendor --into <dependencies-folder> <package-root>...
//
//  Resolves each package's dependencies with SwiftPM and copies every checkout into the
//  Dependencies folder — the package's own by default, or the one `--into` names when a
//  formula includes several packages under one build root
//  (`SwiftFormulaConverter(path: <pkg>, root: <.>)`), so their common closure is vendored
//  once. Run it before pushing the tree; run it again after changing a dependency.

import Foundation
import SemelVendor

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: semel-vendor <package-root>
               semel-vendor --into <dependencies-folder> <package-root>...

        """.utf8))
    exit(64) // EX_USAGE
}

var arguments = Array(CommandLine.arguments.dropFirst())
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
    FileHandle.standardError.write(Data("semel-vendor: \(error)\n".utf8))
    exit(1)
}
