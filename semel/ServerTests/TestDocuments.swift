//
//  TestDocuments.swift
//  SemelServerTests
//
//  What a test publishes for a node that failed: the document a tool printing the text
//  would make. A failure is a document, never a sentence.
//

import SemelNodeKit

extension ErrorDocument {
    /// The document a tool that printed `text` publishes.
    static func failure(_ text: String) -> ErrorDocument {
        .tool(text: text, tool: "test", status: 1, subject: nil)
    }
}

extension NoValueReason {
    /// The reason a node failing with `text` publishes, its document interned.
    static func failure(_ text: String) throws -> NoValueReason {
        try ErrorDocument.failure(text).asReason()
    }
}
