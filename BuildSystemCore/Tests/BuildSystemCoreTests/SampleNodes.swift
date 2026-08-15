//
//  SampleNodes.swift
//  build_system_tests
//
//  Stand-in node types for tests whose subject is the engine, not any particular node.
//
//  CacheTests and PolyFactoryTests used to reach for ClangCompilerTool, which read fine
//  while everything lived in one package and became a dependency on a toolchain the engine
//  no longer knows exists. Their subjects are the cache-key algorithm and the type
//  registry; neither has anything to do with C.
//

@testable import BuildSystemCore
import DatabaseModels
import SemelNodeKit

/// A node with the shape the cache cares about: a configuration port, a content port, and
/// somewhere to put a result. It does nothing when processed — no test here runs it.
public struct SampleTool: NodeFunction {
    public static let kind: UInt = 987_101

    static let configuration = "configuration"
    static let input         = "input"
    static let output        = "output"
    static let errorLog      = "errorLog"
    static let infoLog       = "infoLog"

    public var embeddedNode: Node

    public init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    public static let descriptor = NodeFunctionDescriptor(
        inputPorts: [.required(configuration), .dynamic(input)],
        outputPorts: [output, errorLog, infoLog]
    )

    /// Interns a result, so a test that makes the object store unwritable has something
    /// for the write to fail on.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        .init(outputValues: [Self.output: .value(try "result".intern())],
              inputWireExpectations: [:])
    }
}

/// A second type, for the tests that need two that must not share a cache key or a kind.
public struct OtherSampleTool: NodeFunction {
    public static let kind: UInt = 987_102

    public var embeddedNode: Node

    public init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    public static let descriptor = NodeFunctionDescriptor(
        inputPorts: [.required(SampleTool.configuration)],
        outputPorts: [SampleTool.output]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        .init(outputValues: [:], inputWireExpectations: [:])
    }
}
