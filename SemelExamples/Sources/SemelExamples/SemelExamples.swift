//
//  SemelExamples.swift
//  SemelExamples
//
//  Nodes that exist to be read. A host that wants them calls `register()`; the engine
//  itself knows nothing of them.

import SemelNodeKit

public enum SemelExamples {

    /// Installs the example node types. No tools and no config namespaces: nothing here
    /// runs a tool.
    ///
    /// Idempotent, because a host may call it more than once and every test calls it again.
    public static func register() throws {
        try TypeRegistry.register(types: [
            LineCounter.self,
        ])
    }
}
