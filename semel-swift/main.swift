//
//  main.swift
//  semel-swift
//
//  semel-swift prepare <folder> [--platform macos|ios-simulator] [--xcconfig <name>=<file>]...
//
//  The Swift conversion tool, outside Semel: everything between cloning a tree of Swift
//  packages and `semel 'build <folder>'`. It finds the packages, takes as roots the ones
//  nothing there depends on by path, vendors the roots' dependencies into
//  `<folder>/Dependencies`, and writes `semel.fmla` and `semel.config` beside them unless
//  they are already there. The same command every time: after cloning, and again after
//  changing a dependency — the copies are replaced, the files are kept.

import Foundation
import SemelNodeKit
import SemelSwiftTool

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: semel-swift prepare <folder> [--platform \(Platform.allCases.map(\.rawValue).joined(separator: "|"))] [--xcconfig <name>=<file>]...
          --xcconfig  the file to copy into place as <name>, an xcconfig the project names
                      and the repository does not ship, when no template beside it is found

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
// `--xcconfig <name>=<file>`, as often as there are files to place. The name is the path
// the project names, relative to the folder; the file is relative to where the tool runs.
var xcconfigSources: [String: URL] = [:]
while let flag = arguments.firstIndex(of: "--xcconfig") {
    guard flag + 1 < arguments.count else {
        usage()
    }
    let pair = arguments[flag + 1]
    guard let equals = pair.firstIndex(of: "="), equals > pair.startIndex, pair.index(after: equals) < pair.endIndex else {
        usage()
    }
    xcconfigSources[String(pair[..<equals])] = URL(fileURLWithPath: String(pair[pair.index(after: equals)...]))
    arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.count == 1 else {
    usage()
}
let folder = URL(fileURLWithPath: arguments[0], isDirectory: true)

do {
    let report = try Preparation.run(folder: folder, platform: platform, xcconfigSources: xcconfigSources)
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
    for copy in report.copiedFromTemplate {
        // The source's values are whoever wrote the source's; the simulator takes them,
        // a device build needs the user's own.
        print("Copied: \(copy.file.path) (from \(copy.source.path); edit it if its values are not yours)")
    }
    for file in report.missingXcconfigs {
        print("Missing: \(file.path) (the project names it and nothing here provides it; the build reads it as empty)")
    }
    if !report.undefinedReferences.isEmpty {
        // What the missing file would have to define, so writing it by hand is a matter
        // of these names, not of reading the project.
        print("  Undefined after reading what is there: \(report.undefinedReferences.joined(separator: ", "))")
        print("  Write the file, or name one to copy: --xcconfig <name>=<file>")
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
