//
//  NodeDescriptorTests.swift
//  SemelNodeKitTests
//
//  Whether a type's outputs are cached is declared on its descriptor (B-147). The default is
//  what every type gets unless it says otherwise, so it is pinned here: a type that forgot
//  to declare anything must be cached, never silently recomputed.
//

@testable import SemelNodeKit
import XCTest

final class NodeDescriptorTests: XCTestCase {

    func test_aTypeCachesItsOutputsUnlessItDeclaresOtherwise() {
        let descriptor = NodeDescriptor(inputPorts: [.required("input")], outputPorts: ["output"])

        XCTAssertTrue(descriptor.cachesOutputs)
    }

    func test_aTypeThatDeclaresItDoesNotCacheSaysSo() {
        let descriptor = NodeDescriptor(inputPorts: [.required("input")], outputPorts: ["output"],
                                        cachesOutputs: false)

        XCTAssertFalse(descriptor.cachesOutputs)
    }
}
