//
//  main.swift
//  semel-swift
//
//  semel-swift prepare <folder> [--platform macos|ios-simulator] [--application <target>] [--xcconfig <name>=<file>]...
//
//  The Swift conversion tool, outside Semel: everything between cloning a tree of Swift
//  packages and `semel 'build <folder>'`. It finds the packages, takes as roots the ones
//  nothing there depends on by path, vendors the roots' dependencies into
//  `<folder>/Dependencies`, and writes `semel.fmla` and `semel.config` beside them unless
//  they are already there, and its part of `semel.machine.config` — the machine's tools
//  and SDK — every time, keeping what `semel-clang` wrote there. The platform is the one
//  `semel.config` already holds, else `--platform`, else macOS; a `--platform` the files
//  already there do not build for is an error, and every run says the platform, the SDK
//  and the target it prepared for. The same command every
//  time: after cloning, and again after changing a dependency or a toolchain — a copy whose
//  pin moved, or that is not what its lock says, is replaced with its lock, every other
//  copy and lock is left untouched (B-138), prepare's part of the machine file is
//  rewritten, and the formula and the project's config are kept.

import Foundation
import SemelNodeKit
import SemelSwiftTool

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: semel-swift prepare <folder> [--platform \(Platform.allCases.map(\.rawValue).joined(separator: "|"))] [--application <target>] [--xcconfig <name>=<file>]...
          --platform     the platform to build for: the one the \(GeneratedFiles.configFileName) already there holds,
                         else \(Preparation.defaultPlatform.rawValue); naming another than it holds is an error
          --application  the application target to build, when more than one builds for the
                         platform; otherwise the platform picks it
          --xcconfig     the file to copy into place as <name>, an xcconfig the project names
                         and the repository does not ship, when no template beside it is found

        """.utf8))
    exit(64) // EX_USAGE
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "prepare" else {
    usage()
}
arguments.removeFirst()

var platform: Platform?
if let flag = arguments.firstIndex(of: "--platform") {
    guard flag + 1 < arguments.count, let chosen = Platform(rawValue: arguments[flag + 1]) else {
        usage()
    }
    platform = chosen
    arguments.removeSubrange(flag...(flag + 1))
}
var applicationName: String?
if let flag = arguments.firstIndex(of: "--application") {
    guard flag + 1 < arguments.count else {
        usage()
    }
    applicationName = arguments[flag + 1]
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
    let report = try Preparation.run(folder: folder, platform: platform, application: applicationName,
                                     xcconfigSources: xcconfigSources)
    for line in report.platformLines {
        print(line)
    }
    if let project = report.project {
        print("Project: \(project)")
        if let application = report.application, let buildsFor = report.buildsFor {
            print("  application \(application) for \(buildsFor.platform.sdkName)")
        }
        for package in report.localPackages {
            print("  local package \(package.lastPathComponent) (\(package.path))")
        }
    } else {
        print("Roots:")
        for root in report.roots {
            print("  \(root.name) (\(root.folder.path))")
        }
    }
    if report.vendored.isEmpty {
        print("No dependencies to vendor.")
    }
    for line in report.vendoringLines {
        print(line)
    }
    for zip in report.unzippedArtifacts {
        print("Unzipped: \(zip.path)")
    }
    for artifact in report.artifacts {
        print("Artifact: \(artifact.path)")
    }
    for lock in report.locks {
        print("Locked: \(lock.path)")
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
    for source in report.ungeneratedSources {
        // A scheme's pre-action is outside the build: named, not run, and the build fails
        // where the file's declarations are used until it is there.
        print("Not generated: \(source.output) (from \(source.template), which the project generates before its build)")
        if source.generatedBy.isEmpty {
            print("  No shared scheme's build pre-action runs gyb; generate it as the project documents, or write it")
        }
        for action in source.generatedBy {
            let script = action.script.trimmingCharacters(in: .whitespacesAndNewlines)
            print("  Generated by scheme \(action.scheme)'s build pre-action \"\(action.title)\": \(script)")
        }
        let which: String
        switch source.generatedBy.count {
        case 0:  which = "the generator"
        case 1:  which = "that"
        default: which = "one of these"
        }
        print("  Semel runs no scheme action: run \(which), or write the file, before building")
    }
    for file in report.written {
        print("Written: \(file.path)")
    }
    for kept in report.machineFileKept {
        // Another writer's part of the machine file, left in place (B-109).
        let writer = kept.writer.map { " from \($0)" } ?? ""
        print("  kept in \(GeneratedFiles.machineConfigFileName): \(kept.namespaces.joined(separator: ", "))\(writer)")
    }
    for file in report.kept {
        print("Kept: \(file.path)")
    }
} catch {
    FileHandle.standardError.write(Data("semel-swift: \(error)\n".utf8))
    exit(1)
}
