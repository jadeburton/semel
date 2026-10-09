//
//  TestDocuments.swift
//  SemelCoreTests
//
//  What a test publishes for a node that failed, and how it reads one back. A failure is
//  an `ErrorDocument`, never a sentence: a test that wants "a node failed with X" publishes
//  the document a tool printing X would make, and compares documents.
//

import SemelDatabaseModels
@testable import SemelCore
@testable import SemelNodeKit

extension ErrorDocument {
    /// The document a tool that printed `text` publishes: what a test's failing node says.
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

extension NodeValue {
    /// The document an error value names, read back; nil for a value or another reason.
    var errorDocument: ErrorDocument? {
        guard case .noValue(.error(let hash)) = self else {
            return nil
        }
        return ErrorDocument.read(documentHash: hash)
    }

    /// The condition an error value's document names, or nil for a tool's text, a value or
    /// another reason.
    var errorCondition: ErrorCondition? {
        guard case .engine(let condition)? = errorDocument?.diagnostic else {
            return nil
        }
        return condition
    }
}

extension OutputPort {
    /// The document an error port names, read back.
    var errorDocument: ErrorDocument? {
        guard valueKind == .error, let hash = dataObjectHash else {
            return nil
        }
        return ErrorDocument.read(documentHash: hash)
    }
}
