//
//  CacheKeyMaterialTests.swift
//  semel_tests
//
//  B-13. A key is a hash, and a hash says nothing about what it was taken of. The material
//  is what the hash is taken of, stored beside the entry it keyed, so a mismatch between
//  two builds is a diff of two texts and a key can be recomputed away from the graph that
//  produced it.
//

@testable import SemelCore
import SemelNodeKit
import XCTest

final class CacheKeyMaterialTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeCompilerNode() throws -> SampleTool {
        let (node, _) = try GraphSpecNode.parse("SampleTool()").findOrCreateMatchingNode()
        return try SampleTool(thisNode: node)
    }

    private func makeInput(sourcePath: String = "src/hello.c.p",
                           contents: String = "int main(){}") throws -> ProcessInput {
        ProcessInput(inputValues: [
            SampleTool.configuration: ["configuration": .value(try "toolDescriptor.name=sample".intern())],
            SampleTool.input: [sourcePath: .value(try contents.intern())],
        ])
    }

    private func builtOutput() throws -> ProcessOutput {
        ProcessOutput(outputValues: [SampleTool.output:   .value(try "OBJECT".intern()),
                                     SampleTool.errorLog: .value(""),
                                     SampleTool.infoLog:  .value("")],
                      inputWireSpecs: [:])
    }

    /// Stores one entry and answers the key it was stored under.
    @discardableResult
    private func store(_ tool: SampleTool, input: ProcessInput) throws -> String {
        let material = try tool.buildCacheKeyMaterial(input: input)
        try tool.saveCacheForAllInputsAndOutputs(keyMaterial: material, processingDuration: 0.1,
                                                 output: try builtOutput())
        return try material.cacheKey()
    }

    /// The material of the stored entry with this key, read back from the database and
    /// from nothing else: what someone diagnosing a mismatch has in front of them.
    private func storedMaterial(key: String) throws -> CacheKeyMaterial {
        let row = try XCTUnwrap(engine.database.cacheEntry.select(hash: key))
        return try ProcessCacheEntry.fromJSON(String(decoding: row.content, as: UTF8.self)).keyMaterial
    }

    // MARK: - The key is the hash of the material

    /// The point of storing the material: the key can be recomputed from it alone, so an
    /// entry one machine wrote can be checked against another machine's key without either
    /// graph being present.
    func test_theStoredMaterialRecomputesTheKeyItWasStoredUnder() throws {
        let tool  = try makeCompilerNode()
        let key   = try store(tool, input: try makeInput())

        let material = try storedMaterial(key: key)

        XCTAssertEqual(try material.cacheKey(), key)
    }

    /// The material is not a description of the key written alongside it, which could
    /// drift: the key is the hash of the material's own text, computed nowhere else.
    func test_theKeyIsTheHashOfTheMaterialsText() throws {
        let tool     = try makeCompilerNode()
        let input    = try makeInput()
        let material = try tool.buildCacheKeyMaterial(input: input)

        let key = try tool.buildCacheKeyFromAllInputs(input: input)

        XCTAssertEqual(key, Sha256.hash(Array(try material.canonicalText().utf8)))
    }

    /// Everything the key covers is in the text, named: a reader of one dump can tell
    /// which implementation, which properties and which inputs made the key.
    func test_theMaterialsTextNamesWhatTheKeyCovers() throws {
        let tool = try makeCompilerNode()
        defer { SampleTool.cacheKeyMaterialForTests = nil }
        SampleTool.cacheKeyMaterialForTests = "sdk=abc"

        let text = try tool.buildCacheKeyMaterial(input: try makeInput()).canonicalText()

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, "node SampleTool@1")
        XCTAssertTrue(lines.contains { $0.hasPrefix("fingerprint ") && $0.contains("sdk=abc") },
                      "the material a node reads from outside its inputs is named, got: \(text)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("input ") && $0.contains("src/hello.c.p") },
                      "each wired input is a line of its own, got: \(text)")
    }

    // MARK: - Diffing two entries

    /// The item this was opened for: two builds disagreed, and the answer has to be the
    /// one input that differs rather than two hashes that are not equal.
    func test_twoEntriesDifferingInOneInputDifferInExactlyThatLine() throws {
        let tool = try makeCompilerNode()
        let firstKey  = try store(tool, input: try makeInput(contents: "int main(){}"))
        let secondKey = try store(tool, input: try makeInput(contents: "int main(){return 1;}"))

        let firstLines  = try storedMaterial(key: firstKey).canonicalText().split(separator: "\n").map(String.init)
        let secondLines = try storedMaterial(key: secondKey).canonicalText().split(separator: "\n").map(String.init)

        XCTAssertEqual(firstLines.count, secondLines.count, "the two builds ran the same node over the same wires")
        let differing = zip(firstLines, secondLines).filter { $0 != $1 }
        XCTAssertEqual(differing.count, 1, "one input changed, so one line changed")
        XCTAssertTrue(differing[0].0.hasPrefix("input ") && differing[0].0.contains("src/hello.c.p"),
                      "the line that differs names the wire that differs, got: \(differing[0].0)")
    }

    // MARK: - An entry without material

    /// An entry written before the material was stored is a miss rather than a hit whose
    /// key nothing can account for. It decodes short and is replaced by the build that
    /// missed on it.
    func test_anEntryWithoutMaterialIsAMissAndIsReplaced() throws {
        let tool  = try makeCompilerNode()
        let input = try makeInput()
        let key   = try tool.buildCacheKeyMaterial(input: input).cacheKey()
        let withoutMaterial = #"{"outputValues":{},"inputWireSpecs":{}}"#
        try engine.database.cacheEntry.insert(.init(hash: key, content: [UInt8](withoutMaterial.utf8),
                                                    cost: 1, timestamp: Date()))

        XCTAssertNil(try tool.loadCachedOutputs(cacheKey: key),
                     "an entry whose key nothing accounts for is not an entry to hand back")

        try store(tool, input: input)

        let loaded = try XCTUnwrap(tool.loadCachedOutputs(cacheKey: key),
                                   "the build that missed on it replaces it")
        XCTAssertEqual(try loaded.outputValues[SampleTool.output]?.expectValue().resolveAsString(), "OBJECT")
    }

    // MARK: - Reading it back

    /// The reading surface: an entry's material, by its key, as the text the key is the
    /// hash of — so `shasum -a 256` over the printed block is the key above it. The
    /// description ends one newline short of the material, which is the newline printing it
    /// puts back.
    func test_theMaterialIsReadBackByKey() throws {
        let tool = try makeCompilerNode()
        let key  = try store(tool, input: try makeInput())

        let description = engine.cacheEntryDescription(key: key)

        XCTAssertTrue(description.contains(key), "the entry is named by its key, got: \(description)")
        XCTAssertTrue((description + "\n").hasSuffix(try storedMaterial(key: key).canonicalText()),
                      "the material ends the description as the text that hashes to the key, got: \(description)")
    }

    /// The offline half of the item: what the block prints, hashed by anything at all, is
    /// the key it was printed under.
    func test_theKeyIsRecomputedFromTheBlockThatIsPrinted() throws {
        let tool = try makeCompilerNode()
        let key  = try store(tool, input: try makeInput())

        let description = engine.cacheEntryDescription(key: key)

        let parts = description.components(separatedBy: "key material — its sha256 is the key above:\n")
        XCTAssertEqual(parts.count, 2, "the block is introduced once, got: \(description)")
        // The newline printing the description adds back, which a shell pipeline carries.
        XCTAssertEqual(Sha256.hash(Array((parts[1] + "\n").utf8)), key)
    }

    func test_anUnknownKeySaysSoRatherThanPrintingNothing() throws {
        let description = engine.cacheEntryDescription(key: String(repeating: "0", count: 64))

        XCTAssertTrue(description.contains("no cache entry"), "got: \(description)")
    }
}
