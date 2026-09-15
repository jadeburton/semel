//
//  main.swift
//  semel-swift
//
//  semel-swift prepare <folder> [--platform macos|ios-simulator]
//
//  The Swift conversion tool, outside Semel: everything between cloning a tree of Swift
//  packages and `semel 'build <folder>'`. It finds the packages, takes as roots the ones
//  nothing there depends on by path, vendors the roots' dependencies into
//  `<folder>/Dependencies`, and writes `semel.fmla` and `semel.config` beside them unless
//  they are already there. The same command every time: after cloning, and again after
//  changing a dependency — the copies are replaced, the files are kept.

import Foundation
import SemelSwiftTool

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: semel-swift prepare <folder> [--platform \(Platform.allCases.map(\.rawValue).joined(separator: "|"))]

        """.utf8))
    exit(64) // EX_USAGE
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "prepare" else {
    usage()
}
arguments.removeFirst()

var platform = Platform.macos
var platformWasGiven = false
if let flag = arguments.firstIndex(of: "--platform") {
    guard flag + 1 < arguments.count, let chosen = Platform(rawValue: arguments[flag + 1]) else {
        usage()
    }
    platform = chosen
    platformWasGiven = true
    arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.count == 1 else {
    usage()
}
let folder = URL(fileURLWithPath: arguments[0], isDirectory: true)

do {
    let report = try Preparation.run(folder: folder, platform: platform)
    if let project = report.project {
        print("Project: \(project)")
    } else {
        print("Roots:")
        for root in report.roots {
            print("  \(root.name) (\(root.folder.path))")
        }
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
        // A config already there is the one the build reads; a platform named on this
        // run changed nothing, and silence would let the user believe otherwise.
        let note = platformWasGiven && file.lastPathComponent == GeneratedFiles.configFileName
            ? " (--platform has no effect on a config that is there; delete it to regenerate)"
            : ""
        print("Kept: \(file.path)\(note)")
    }
} catch {
    FileHandle.standardError.write(Data("semel-swift: \(error)\n".utf8))
    exit(1)
}
