//
//  SampleNodes.swift
//  build_system_tests
//
//  Stand-in node types for tests whose subject is the engine, not any particular node.
//
//  CacheTests and PolyFactoryTests would otherwise reach for a real toolchain node, which
//  the engine's package cannot see and should not need to. Their subjects are the cache-key
//  algorithm and the type registry; neither has anything to do with C.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit

/// A node with the shape the cache cares about: a configuration port, a content port, and
/// somewhere to put a result. It does nothing when processed — no test here runs it.
public struct SampleTool: Node {
    public static let kind: UInt = 987_101

    static let configuration = "configuration"
    static let input         = "input"
    static let output        = "output"
    static let errorLog      = "errorLog"
    static let infoLog       = "infoLog"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
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
public struct OtherSampleTool: Node {
    public static let kind: UInt = 987_102

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(SampleTool.configuration)],
        outputPorts: [SampleTool.output]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        .init(outputValues: [:], inputWireExpectations: [:])
    }
}

/// A node with no input ports at all — the shape a `StaticFile` or a `Folder` has.
///
/// Exists so the source/processing distinction can be tested without dragging in the file
/// system. `process` is unreachable in a working graph; it throws rather than trapping,
/// because enforcing the engine's invariants is not a node's job and a third-party node
/// should not be able to bring the process down.
public struct SampleSourceNode: Node {
    public static let kind: UInt = 987_103

    static let output = "output"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(inputPorts: [], outputPorts: [output])

    public func process(input: ProcessInput) throws -> ProcessOutput {
        throw NodeError.other(message: "\(Self.self) declares no input ports and cannot process")
    }
}
