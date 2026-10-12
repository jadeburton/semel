//
//  main.swift
//  semel-cmake
//
//  semel-cmake [<folder>] [--platform macos|ios-simulator]
//
//  Translates a CMake project into a formula (B-157): reads the folder's CMakeLists.txt
//  and the files it reaches, and writes `semel.fmla` and `semel.config` beside it from
//  the declarative subset of what they say — targets, sources, include folders, defines,
//  options and links — refusing the procedural rest by name and line, which the formula's
//  header comment and this tool's output both list. A file already there is kept: the
//  formula is the person's to edit from the first run on. Then writes the clang part of
//  `semel.machine.config`, as `semel-clang` does.

import Foundation
import SemelCMakeTool
import SemelNodeKit

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: semel-cmake [<folder>] [--platform \(Platform.allCases.map(\.rawValue).joined(separator: "|"))]
          writes semel.fmla and semel.config from <folder>/CMakeLists.txt, the current folder by
          default, keeping either file that is already there; and the clang tools into
          <folder>/semel.machine.config, as semel-clang would

        """.utf8))
    exit(64) // EX_USAGE
}

var arguments = Array(CommandLine.arguments.dropFirst())

var platform = Platform.macos
if let flag = arguments.firstIndex(of: "--platform") {
    guard flag + 1 < arguments.count, let chosen = Platform(rawValue: arguments[flag + 1]) else {
        usage()
    }
    platform = chosen
    arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.count <= 1, !(arguments.first?.hasPrefix("-") ?? false) else {
    usage()
}
let folder = URL(fileURLWithPath: arguments.first ?? ".", isDirectory: true).standardizedFileURL

do {
    let report = try CMakeConversion.run(folder: folder, platform: platform)
    print("Project: \(report.projectName ?? "(no project() call)"), for \(report.target)")
    for target in report.targets {
        let product = target.product.map { " → \($0)" } ?? " (nothing to build)"
        print("  \(target.kind) \(target.name)\(product)")
    }
    if !report.untranslated.isEmpty {
        print("Not translated, the rest is:")
        for line in report.untranslated {
            print("  \(line)")
        }
    }
    for file in report.written {
        print("Written: \(file.path)")
    }
    for file in report.kept {
        print("Kept: \(file.path)")
    }
    for line in report.machineFileLines {
        print(line)
    }
} catch {
    FileHandle.standardError.write(Data("semel-cmake: \(error)\n".utf8))
    exit(1)
}
