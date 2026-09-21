//
//  ToolSandbox.swift
//  SemelNodeKit
//
//  What a tool is allowed to know about the directory it runs in.
//

import Foundation

/// The contract every `ToolRunner` keeps with the nodes that call it.
///
/// A tool runs in a fresh directory of its own, with its inputs materialised below that
/// directory at their wire keys — an input-file-system path such as `input:/c/src/hello.c`
/// — and with that directory as its working directory. Every path a node puts on a
/// command line is relative to it. The directory's real name is therefore never on a
/// command line and never in an output, so a tool run at a different mount, or on a
/// different machine, writes the same bytes.
///
/// Where a tool insists on recording a directory name anyway — a compiler's debug
/// information records the compilation directory — the nodes tell it this name instead.
public enum ToolSandbox {

    /// The name a tool is told the sandbox root is called, so that a path it records
    /// names the build rather than the directory this run happened to get. Never a real
    /// directory: nothing resolves it, nothing creates it, and the tool never opens it.
    public static let canonicalRootName = "/semel"
}
