//
//  TestSupport.swift
//  SemelExamplesTests
//
//  The same isolation the toolchain packages' tests use: a package that only needs the
//  node-authoring API swaps the process-globals a node can reach, and nothing more.
//

@testable import SemelExamples
import Foundation
import SemelNodeKit
import XCTest

/// Base class for every test here: no test writes to the user's object store.
class SemelExamplesTestCase: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: Self.temporaryStoreRoot())
        try SemelExamples.register()
    }

    private static func temporaryStoreRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-examples-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
