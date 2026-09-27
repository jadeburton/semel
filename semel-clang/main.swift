//
//  main.swift
//  semel-clang
//
//  semel-clang [<folder>] [--platform macos|ios-simulator] [--force]
//
//  The C and C++ counterpart of semel-swift, outside Semel (B-119): writes
//  `semel.machine.config` — the clang this machine has and the SDK for the platform — into
//  the folder, the current one by default. Only when there is none: `--force` rewrites it,
//  after a toolchain update, say. Nobody edits the file, and nobody commits it.

import Foundation
import SemelClangTool
import SemelNodeKit

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: semel-clang [<folder>] [--platform \(Platform.allCases.map(\.rawValue).joined(separator: "|"))] [--force]
          writes semel.machine.config for the clang tools into <folder>, the current folder by default,
          unless one is there; --force rewrites it

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
    switch try ClangMachineFile.write(into: folder, platform: platform, force: force) {
    case .written(let file, let namespaces, let notInstalled):
        print("Wrote \(file.path): \(namespaces.joined(separator: ", "))")
        if !notInstalled.isEmpty {
            print("No \(notInstalled.joined(separator: ", ")) is installed here; those blocks are comments.")
        }
    case .kept(let file):
        print("Kept \(file.path): it is already there; --force rewrites it")
    }
} catch {
    FileHandle.standardError.write(Data("semel-clang: \(error)\n".utf8))
    exit(1)
}
