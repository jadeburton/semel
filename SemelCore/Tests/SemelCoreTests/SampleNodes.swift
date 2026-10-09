//
//  SampleNodes.swift
//  semel_tests
//
//  Stand-in node types for tests whose subject is the engine, not any particular node.
//
//  CacheTests and TypeRegistryTests would otherwise reach for a real toolchain node, which
//  the engine's package cannot see and should not need to. Their subjects are the cache-key
//  algorithm and the type registry; neither has anything to do with C.
//

@testable import SemelCore
import Foundation
import SemelDatabaseModels
import SemelNodeKit

/// A node with the shape the cache cares about: a configuration port, a content port, and
/// somewhere to put a result. Processing it does no work worth the name — it interns a
/// fixed string — so a test that drives it is testing the engine around it.
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

    /// How long `process` takes. Zero unless a test sets it, and a test that wants this
    /// node's result *cached* has to: the cache declines to store anything that took less
    /// than its floor, on the grounds that such an entry costs more than recomputing.
    static var processingDurationForTests: TimeInterval = 0

    /// Interns a result, so a test that makes the object store unwritable has something
    /// for the write to fail on. Every declared port is written: a node that leaves one
    /// unwritten is warned about and left scheduled.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        if Self.processingDurationForTests > 0 {
            Thread.sleep(forTimeInterval: Self.processingDurationForTests)
        }
        return .init(outputValues: [Self.output:   .value(try "result".intern()),
                                    Self.errorLog: .value(try "".intern()),
                                    Self.infoLog:  .value(try "".intern())],
                     inputWireSpecs: [:])
    }

    /// What this tool claims to read from outside its inputs beyond its tool binary. Nil,
    /// as for most nodes, unless a test sets it — CacheTests uses it to pin how the hook
    /// reaches the key.
    static var cacheKeyMaterialForTests: String?

    /// A stand-in for a real tool node, which declares the binary behind the tool its
    /// configuration names. A test's own material takes the place of the whole thing, so
    /// what reaches the key stays exactly what that test put there.
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        if let material = Self.cacheKeyMaterialForTests {
            return material
        }
        return try toolBinaryCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }

    /// Which implementation of this node type a test is standing in for. A shipped node
    /// type declares a constant and bumps it by editing the source; a test needs two
    /// implementations of one type within a single run, which only a variable gives.
    static var implementationVersionForTests: Int = 1

    public static var implementationVersion: Int { implementationVersionForTests }
}

/// A node that insists on its input's value, the way a tool reads the files it compiles.
///
/// The insisting is the point: `expectValue()` throws when there is no value to be had, and
/// what the engine does with that throw — write the state, not a sentence — is what a test
/// of the states needs a node for.
public struct DemandingSampleTool: Node {
    public static let kind: UInt = 987_104

    static let input  = "input"
    static let output = "output"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(input)],
        outputPorts: [output]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        var text = ""
        for (_, value) in (input.inputValues[Self.input] ?? [:]).sorted(by: { $0.key < $1.key }) {
            text += try value.expectValue().resolveAsString()
        }
        return .init(outputValues: [Self.output: .value(try text.intern())], inputWireSpecs: [:])
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
        .init(outputValues: [:], inputWireSpecs: [:])
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
        throw NodeError.sourceCannotProcess(type: "\(Self.self)")
    }
}
