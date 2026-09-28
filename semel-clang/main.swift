//
//  main.swift
//  semel-clang
//
//  semel-clang [<folder>] [--platform macos|ios-simulator] [--force]
//
//  The C and C++ counterpart of semel-swift, outside Semel (B-119): writes the clang part of
//  `semel.machine.config` — the clang this machine has and the SDK for the platform — into
//  the folder, the current one by default: the namespaces the formulas reading it select,
//  or every clang namespace when none does. Another writer's namespaces in the file are
//  kept. A file already holding what it would write is left as it is: `--force` rewrites
//  it, after a toolchain update, say. Nobody edits the file, and nobody commits it.

import Foundation
import SemelClangTool
import SemelNodeKit

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: semel-clang [<folder>] [--platform \(Platform.allCases.map(\.rawValue).joined(separator: "|"))] [--force]
          writes the clang tools into <folder>/semel.machine.config, the current folder by default,
          keeping another tool's; unless the file holds them already, which --force rewrites

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
let force = arguments.contains("--force")
arguments.removeAll { $0 == "--force" }
guard arguments.count <= 1, !(arguments.first?.hasPrefix("-") ?? false) else {
    usage()
}
let folder = URL(fileURLWithPath: arguments.first ?? ".", isDirectory: true).standardizedFileURL

do {
    try ClangMachineFile.write(into: folder, platform: platform, force: force).lines.forEach { print($0) }
} catch {
    FileHandle.standardError.write(Data("semel-clang: \(error)\n".utf8))
    exit(1)
}
