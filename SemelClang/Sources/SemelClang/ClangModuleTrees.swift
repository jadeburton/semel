// ClangModuleTrees.swift
// SemelClang
//
// The module trees of the package products a target links, as both clang stages take them.

import Foundation
import SemelNodeKit

/// The trees on a `moduleTrees` port — what a package's `modules_P()` carries: its targets'
/// modules and, for a C-family target, its headers and module map under the target's name —
/// merged under `modules`, with every folder holding a `module.modulemap` an `-I` (B-77 item 4).
///
/// An application's Objective-C imports a package's Objective-C module by name, as Sequel
/// Ace's `@import FMDB;` does; the preprocessor loads it to read its macros, and leaves a
/// `#pragma clang module import` in its output for the compiler to load again. Both stages
/// are given the same trees, as the Swift compiler is (`SwiftCompiler.inputModuleTrees`).
struct ClangModuleTrees {
    /// The sandbox folder the trees are merged into.
    static let folder = "modules"

    /// Every file of every tree, under `modules`.
    let files: [FileNameAndContent]
    /// Each folder holding a module map, sorted.
    let searchPaths: [String]

    init(input: ProcessInput, port: String) throws {
        files = try TreeManifest.mergedInputFiles(in: input, port: port, under: Self.folder)
        let folders = files.compactMap { file -> String? in
            guard Path(file.filePath).lastComponent == "module.modulemap" else {
                return nil
            }
            return Path(file.filePath).deletingLastComponent?.string
        }
        searchPaths = Set(folders).sorted()
    }

    /// `-I` for each folder holding a module map.
    var arguments: [String] {
        searchPaths.flatMap { ["-I", $0] }
    }
}
