// SemelClang.swift
// SemelClang
//
// What this package contributes, and how a host installs it.
//
// Unlike SemelSwift there is no project kind here: a C or C++ project is described by a
// `.fmla` file, which the engine recognises itself because a formula names no toolchain.
// So this package contributes node types and nothing else.

import SemelNodeKit

public enum SemelClang {

    /// Installs this toolchain's node types. Idempotent, so a host may call it more than
    /// once and every test calls it again.
    public static func register() throws {
        try PolyFactory.register(types: [
            ClangCompilerTool.self,
            ClangLinkerTool.self,
            ClangPreprocessorTool.self,
            ClangIncludeFinder.self,
        ])
    }
}
