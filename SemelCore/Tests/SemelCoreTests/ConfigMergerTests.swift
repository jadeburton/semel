//
//  ConfigMergerTests.swift
//  SemelCoreTests
//
//  Laying one config over another, so a shared base is written once.
//
//  This is the only way one config builds on another now that inheritance is gone, and the
//  whole point is that precedence is explicit: which file wins is the port it is wired to, not
//  an ordering someone has to know about. These pin that, and pin the absent-wire reading that
//  makes an override file optional.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ConfigMergerTests: SemelCoreTestCase {

    /// Runs the node over the two ports. `nil` means the wire exists but carries no value —
    /// a file named in the formula that nobody has written yet.
    ///
    /// Deliberately an *error* rather than a pending value, because that is what actually
    /// arrives: a `StaticFile` nobody has pushed publishes `noValue(.error)`. A pending value
    /// would not reach `process` at all — `allInputsAreSatisfied` waits on pending — so a test
    /// using one would assert nothing about how this node behaves.
    private func merge(base: String?, override: String?) throws -> String {
        let node = try ConfigMerger(thisNode: NodeRecord(id: 1, kind: ConfigMerger.kind))

        func wire(_ text: String?) -> [String: NodeValue] {
            guard let text else {
                return ["config": .noValue(reason: .error(messageDataObjectHash: (try? "absent".intern()) ?? ""))]
            }
            return ["config": .value((try? text.intern()) ?? "")]
        }

        let output = try node.process(input: ProcessInput(inputValues: [
            ConfigMerger.basePort: wire(base),
            ConfigMerger.overridePort: wire(override),
        ]))
        return try XCTUnwrap(output.outputValues[ConfigMerger.outputPort])
            .expectValue().resolveAsString()
    }

    // MARK: - Precedence

    func test_theOverrideWinsOnAKeyBothSet() throws {
        let result = try merge(base: "a=base", override: "a=override")

        XCTAssertEqual(result, "a=override")
    }

    /// The point of a base: a project states only what it changes, and everything else it
    /// still gets. Without this the node would be a way to replace a file, not extend it.
    func test_keysOnlyTheBaseSetsSurvive() throws {
        let result = try merge(base: "a=1\nb=2", override: "b=changed")

        XCTAssertEqual(result, "a=1\nb=changed")
    }

    func test_keysOnlyTheOverrideSetsAreAdded() throws {
        let result = try merge(base: "a=1", override: "b=2")

        XCTAssertEqual(result, "a=1\nb=2")
    }

    // MARK: - A wire with nothing on it

    /// An override file a formula names but nobody has written yet. The base has to pass
    /// through whole, or a project with nothing to override could not build until someone
    /// created an empty file for it.
    func test_anAbsentOverrideLetsTheBaseThrough() throws {
        let result = try merge(base: "a=1\nb=2", override: nil)

        XCTAssertEqual(result, "a=1\nb=2")
    }

    /// The reverse, for the same reason: naming a base that does not exist yet leaves what the
    /// project itself says, rather than failing.
    func test_anAbsentBaseLeavesTheOverride() throws {
        let result = try merge(base: nil, override: "a=1")

        XCTAssertEqual(result, "a=1")
    }

    func test_bothAbsentIsAnEmptyConfiguration() throws {
        XCTAssertEqual(try merge(base: nil, override: nil), "")
    }

    // MARK: - Determinism

    /// This becomes a wire value, and a wire value is compared for equality to decide whether
    /// anything downstream needs to run. An unsorted render would make an unchanged
    /// configuration look changed on the next process.
    func test_theOutputIsSorted() throws {
        let result = try merge(base: "zebra=1\nalpha=2", override: "middle=3")

        XCTAssertEqual(result, "alpha=2\nmiddle=3\nzebra=1")
    }

    /// Comments are the parser's business, not this node's, but a merged file is one a person
    /// reads — so a commented-out key in the override must not shadow the base's real one.
    func test_aCommentedKeyInTheOverrideDoesNotShadowTheBase() throws {
        let result = try merge(base: "a=1", override: "// a=2")

        XCTAssertEqual(result, "a=1")
    }

    // MARK: - What the ports require

    /// An optional port means a formula may leave that input out, and a merger written with
    /// one side is that side — so requiring both is what stops the node being written where
    /// wiring the config directly is what was meant.
    ///
    /// This says nothing about a config file that has not been written yet: naming a file in
    /// a formula creates its wire regardless, and the tests above cover a wire that carries
    /// no value. The two are separate, and conflating them is how these ports were optional
    /// to begin with.
    func test_bothPortsAreRequiredSoAOneSidedMergerCannotBeWritten() {
        let required = ConfigMerger.descriptor.inputPorts.compactMap {
            if case .required(let name) = $0 {
                return name
            } else {
                return nil
            }
        }

        XCTAssertEqual(required.sorted(), [ConfigMerger.basePort, ConfigMerger.overridePort].sorted())
    }

    // MARK: - Reachable from a formula

    /// A node type is useless until the factory knows its name: `GraphSpecApplier` resolves a
    /// formula's type names through `TypeRegistry`, so a type that compiles, has a kind and is
    /// never registered fails at graph-build time with `unknownTypeName` — after the formula
    /// has parsed, which makes it read like a language problem rather than a missing
    /// registration.
    func test_theFactoryKnowsThisTypeByName() throws {
        try BuildEngine.registerTypes()

        XCTAssertEqual(try TypeRegistry.kind(forTypeName: "ConfigMerger"), ConfigMerger.kind)
    }

    /// The whole way round: a formula naming this node builds a real graph node.
    func test_aFormulaNamingItBuildsANode() throws {
        let engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        defer { BuildEngine.shared = nil }

        let spec = try GraphSpecNode.parse("""
            ConfigMerger(base: ["b": StaticFile(path: 'input:/base.cfg').output], \
            override: ["o": StaticFile(path: 'input:/local.cfg').output]).output
            """)
        let (node, _) = try spec.findOrCreateMatchingNode()

        XCTAssertEqual(node.kind, ConfigMerger.kind)
    }

    // MARK: - Composing

    /// Three files need two mergers, because a port has no stated precedence between two wires
    /// on it — chaining is what keeps every step explicit.
    func test_mergersChainToComposeThreeConfigs() throws {
        let lower = try merge(base: "a=1\nb=1\nc=1", override: "b=2\nc=2")
        let result = try merge(base: lower, override: "c=3")

        XCTAssertEqual(result, "a=1\nb=2\nc=3")
    }
}
