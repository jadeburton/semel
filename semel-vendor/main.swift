//
//  main.swift
//  semel-vendor
//
//  semel-vendor <package-root>
//
//  Resolves the package's dependencies with SwiftPM and copies every checkout into
//  <package-root>/Dependencies/<name>, the one place Semel looks for them. Run it before
//  pushing the tree; run it again after changing a dependency.

import Foundation
import SemelVendor

let arguments = CommandLine.arguments.dropFirst()

guard arguments.count == 1, let root = arguments.first else {
    FileHandle.standardError.write(Data("usage: semel-vendor <package-root>\n".utf8))
    exit(64) // EX_USAGE
}

do {
    let copied = try Vendoring.vendor(packageRoot: URL(fileURLWithPath: root, isDirectory: true))
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
