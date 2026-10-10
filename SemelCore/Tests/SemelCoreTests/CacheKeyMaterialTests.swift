//
//  CacheKeyMaterialTests.swift
//  semel_tests
//
//  B-13. A key is a hash, and a hash says nothing about what it was taken of. The material
//  is what the hash is taken of, stored beside the entry it keyed, so a mismatch between
//  two builds is a diff of two texts and a key can be recomputed away from the graph that
//  produced it.
//

import GRDB
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
        try makeInput(wires: [sourcePath], contents: contents)
    }

    /// One input per named wire, all carrying the same content: what a test of the wire
    /// *names* in a key wants, the value being the part it is not about.
    private func makeInput(wires: [String], contents: String = "int main(){}") throws -> ProcessInput {
        let value = NodeValue.value(try contents.intern())
        return ProcessInput(inputValues: [
            SampleTool.configuration: ["configuration": .value(try "toolDescriptor.name=sample".intern())],
            SampleTool.input: Dictionary(uniqueKeysWithValues: wires.map { ($0, value) }),
        ])
    }

    /// One wire carrying whatever a test hands it: a value, or a reason there is none.
    private func makeInput(carrying value: NodeValue, wire: String = "src/hello.c.p") throws -> ProcessInput {
        ProcessInput(inputValues: [
            SampleTool.configuration: ["configuration": .value(try "toolDescriptor.name=sample".intern())],
            SampleTool.input: [wire: value],
        ])
    }

    /// The lines of a material's text, which is what a reader diffs and what the key is
    /// the hash of.
    private func lines(of material: CacheKeyMaterial) throws -> [String] {
        try material.canonicalText().split(separator: "\n").map(String.init)
    }

    /// A row under `key` holding content of a shape this Semel does not read.
    private func storeAnUnreadableRow(key: String) throws {
        let withoutMaterial = #"{"outputValues":{},"inputWireSpecs":{}}"#
        try engine.database.cacheEntry.save(hash: key, nodeType: "SampleTool", cost: 1,
                                            content: Data(withoutMaterial.utf8), objects: [])
    }

    private func builtOutput() throws -> AppliedOutput {
        AppliedOutput(outputValues: [SampleTool.output:   .value(try "OBJECT".intern()),
                                     SampleTool.errorLog: .value(""),
                                     SampleTool.infoLog:  .value("")],
                      specTable: GraphSpecTable(inputWireSpecs: [:], rows: [:]))
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

    // MARK: - A value cannot forge a line

    /// The reason each line carries JSON rather than plain text. A wire name holding a
    /// newline would otherwise put a line of its own into the text, and two builds whose
    /// names differ only in where that newline sits would hash alike — a collision, which
    /// is the one failure a cache must never have.
    func test_twoMaterialsDifferingOnlyInWhereANewlineSitsDoNotShareAKey() throws {
        let tool = try makeCompilerNode()

        let first  = try tool.buildCacheKeyMaterial(input: try makeInput(wires: ["a\nb", "c"]))
        let second = try tool.buildCacheKeyMaterial(input: try makeInput(wires: ["a", "b\nc"]))

        XCTAssertEqual(try lines(of: first).count, 4, "one node line, one configuration wire, two input wires")
        XCTAssertEqual(try lines(of: second).count, 4, "the newline is escaped, so it adds no line")
        XCTAssertNotEqual(try first.cacheKey(), try second.cacheKey())
    }

    /// The same for the text a node declares about what it read from outside its inputs,
    /// which is raw text of the node's own choosing — including a newline and the quotes
    /// that would otherwise close a JSON string early.
    func test_aFingerprintCannotForgeALineWithANewlineOrAQuote() throws {
        let tool = try makeCompilerNode()
        defer { SampleTool.cacheKeyMaterialForTests = nil }

        SampleTool.cacheKeyMaterialForTests = "sdk=a"
        let plain = try tool.buildCacheKeyMaterial(input: try makeInput())
        SampleTool.cacheKeyMaterialForTests = "sdk=a\ninput {\"port\":\"input\",\"value\":\"forged\",\"wire\":\"x\"}"
        let forging = try tool.buildCacheKeyMaterial(input: try makeInput())
        SampleTool.cacheKeyMaterialForTests = "sdk=\"a\""
        let quoted = try tool.buildCacheKeyMaterial(input: try makeInput())

        XCTAssertEqual(try lines(of: plain).count, 4, "one node line, one fingerprint, two input wires")
        XCTAssertEqual(try lines(of: forging).count, 4, "a fingerprint holding a whole input line is still one line")
        XCTAssertEqual(try lines(of: quoted).count, 4)
        XCTAssertNotEqual(try plain.cacheKey(), try forging.cacheKey())
        XCTAssertNotEqual(try plain.cacheKey(), try quoted.cacheKey())
        XCTAssertNotEqual(try forging.cacheKey(), try quoted.cacheKey())
    }

    // MARK: - A wire carrying no value

    /// A wire can reach a key carrying a reason instead of a value: only `.pending` stops a
    /// node from running. The reason is coded whole, payload included — collapsing a
    /// failure to the word `error` would hash two different upstream failures alike, and a
    /// node that reads its input's error text emits something different for each.
    func test_twoFailuresWithDifferentMessagesDoNotShareAKey() throws {
        let tool = try makeCompilerNode()
        let firstMessage = try "undefined symbol 'a'".intern()

        let first = try tool.buildCacheKeyMaterial(
            input: try makeInput(carrying: .noValue(reason: .error(documentHash: firstMessage))))
        let second = try tool.buildCacheKeyMaterial(
            input: try makeInput(carrying: .noValue(reason: .error(
                documentHash: try "undefined symbol 'b'".intern()))))
        let cascade = try tool.buildCacheKeyMaterial(
            input: try makeInput(carrying: .noValue(reason: .inputInError)))

        let firstText = try first.canonicalText()
        XCTAssertTrue(firstText.contains(firstMessage), "the message is in the text, got: \(firstText)")
        XCTAssertNotEqual(try first.cacheKey(), try second.cacheKey(),
                          "two failures carrying different messages are two different inputs")
        XCTAssertNotEqual(try first.cacheKey(), try cascade.cacheKey(),
                          "a failure of its own and one above it are two different inputs")
    }

    /// The other half of coding a reason by hand: it has to come back. An entry whose input
    /// carried a reason is decodable, and the reason it carried survives the round trip
    /// with its payload — otherwise the material would account for a key it cannot
    /// recompute.
    func test_aWiredReasonComesBackFromTheStoredMaterial() throws {
        let tool        = try makeCompilerNode()
        let messageHash = try "undefined symbol 'main'".intern()
        let input = try makeInput(carrying: .noValue(reason: .error(documentHash: messageHash)))
        let key   = try store(tool, input: input)

        XCTAssertNotNil(try tool.loadCachedOutputs(cacheKey: key), "the entry decodes, reasons and all")

        let material = try storedMaterial(key: key)
        let entry = try XCTUnwrap(material.inputs.first { $0.port == SampleTool.input })
        guard case .noValue(let reason) = entry.value, case .error(let hash) = reason else {
            return XCTFail("the wire came back carrying \(entry.value)")
        }
        XCTAssertEqual(hash, messageHash)
        XCTAssertEqual(try material.cacheKey(), key, "and the material still accounts for the key")
    }

    // MARK: - An entry without material

    /// An entry written before the material was stored is a miss rather than a hit whose
    /// key nothing can account for. It decodes short and is replaced by the build that
    /// missed on it.
    func test_anEntryWithoutMaterialIsAMissAndIsReplaced() throws {
        let tool  = try makeCompilerNode()
        let input = try makeInput()
        let key   = try tool.buildCacheKeyMaterial(input: input).cacheKey()
        try storeAnUnreadableRow(key: key)

        XCTAssertNil(try tool.loadCachedOutputs(cacheKey: key),
                     "an entry whose key nothing accounts for is not an entry to hand back")

        try store(tool, input: input)

        let loaded = try XCTUnwrap(tool.loadCachedOutputs(cacheKey: key),
                                   "the build that missed on it replaces it")
        XCTAssertEqual(try loaded.outputValues[SampleTool.output]?.expectValue().resolveAsString(), "OBJECT")
    }

    /// A row standing that this Semel cannot read is replaced by the build that missed on
    /// it, however quick that build was: nothing else can put a readable entry in its slot.
    func test_anUnreadableRowIsReplacedByTheBuildThatMissedOnIt() throws {
        let tool  = try makeCompilerNode()
        let input = try makeInput()
        let material = try tool.buildCacheKeyMaterial(input: input)
        let key = try material.cacheKey()
        try storeAnUnreadableRow(key: key)

        try tool.saveCacheForAllInputsAndOutputs(keyMaterial: material, processingDuration: 0,
                                                 output: try builtOutput())

        XCTAssertNotNil(try tool.loadCachedOutputs(cacheKey: key),
                        "the row nothing could read is the one this build stored over")
    }

    /// Whether an entry is stored is the type's declaration, never the run's duration: a
    /// build that took no time at all is stored like any other (B-147).
    func test_aBuildThatTookNoTimeIsStored() throws {
        let tool  = try makeCompilerNode()
        let input = try makeInput()
        let material = try tool.buildCacheKeyMaterial(input: input)

        try tool.saveCacheForAllInputsAndOutputs(keyMaterial: material, processingDuration: 0,
                                                 output: try builtOutput())

        XCTAssertNotNil(try tool.loadCachedOutputs(cacheKey: try material.cacheKey()))
    }

    /// A type declared not to cache stores nothing however long it ran, and a row standing
    /// under its key — one a Semel that cached the type wrote — answers nothing either.
    func test_aTypeDeclaredNotToCacheStoresNothingAndHitsNothing() throws {
        let (node, _) = try GraphSpecNode(UncachedSampleTool.self).findOrCreateMatchingNode()
        let tool  = try UncachedSampleTool(thisNode: node)
        let input = ProcessInput(inputValues: [
            SampleTool.configuration: ["configuration": .value(try "toolDescriptor.name=sample".intern())],
        ])
        let material = try tool.buildCacheKeyMaterial(input: input)
        let key = try material.cacheKey()
        let output = AppliedOutput(outputValues: [SampleTool.output: .value(try "OBJECT".intern())],
                                   specTable: GraphSpecTable(inputWireSpecs: [:], rows: [:]))

        try tool.saveCacheForAllInputsAndOutputs(keyMaterial: material, processingDuration: 10, output: output)
        XCTAssertNil(try engine.database.cacheEntry.select(hash: key), "a type that does not cache writes no row")

        let entry = ProcessCacheEntry(outputValues: output.outputValues, specTable: output.specTable,
                                      keyMaterial: material)
        try engine.database.cacheEntry.save(hash: key, nodeType: material.nodeType, cost: 1,
                                            content: Data(try entry.toJSON().utf8), objects: [])
        XCTAssertNil(try tool.loadCachedOutputs(cacheKey: key), "and is not answered from a row that stands")
    }

    // MARK: - What a lookup counts as recently used

    /// Eviction spares what the last settle used, so a lookup that stamped a row before
    /// reading it would spare the rows it rejects.
    func test_aRejectedRowIsNotStampedAsUsedByTheLookupThatRejectsIt() throws {
        let tool = try makeCompilerNode()
        let key  = try tool.buildCacheKeyMaterial(input: try makeInput()).cacheKey()
        try storeAnUnreadableRow(key: key)
        let written = try XCTUnwrap(engine.database.cacheEntry.select(hash: key)).lastUse
        try engine.database.cacheEntry.closeSettle()

        XCTAssertNil(try tool.loadCachedOutputs(cacheKey: key))

        let row = try XCTUnwrap(engine.database.cacheEntry.select(hash: key))
        XCTAssertEqual(row.lastUse, written, "a row nothing could use is not a row that was used")
    }

    /// The other half: a row that is handed back is used by the settle that read it.
    func test_aRowThatIsHandedBackIsStampedWithTheSettleThatReadIt() throws {
        let tool = try makeCompilerNode()
        let key  = try store(tool, input: try makeInput())
        try engine.database.cacheEntry.closeSettle()

        XCTAssertNotNil(try tool.loadCachedOutputs(cacheKey: key))

        let row = try XCTUnwrap(engine.database.cacheEntry.select(hash: key))
        XCTAssertEqual(row.lastUse, try engine.database.cacheEntry.account().settle)
        XCTAssertGreaterThan(row.lastUse, try engine.database.cacheEntry.account().lastUsingSettle)
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

    /// A row this Semel cannot read is the state a reader meets least often and can check
    /// least easily, so it is said in full: what the row is, and what becomes of it.
    func test_aRowThisSemelCannotReadIsDescribedRatherThanPrintedEmpty() throws {
        let key = String(repeating: "a", count: 64)
        try storeAnUnreadableRow(key: key)

        let description = engine.cacheEntryDescription(key: key)

        XCTAssertTrue(description.contains("cache entry \(key)"), "got: \(description)")
        XCTAssertTrue(description.contains("not of a shape this Semel reads"), "got: \(description)")
        XCTAssertTrue(description.contains("replaces it"), "it says what becomes of it, got: \(description)")
    }

    /// A row whose material does not account for the key it is filed under is damaged —
    /// the one thing this dump exists to make visible, so it cannot be answered with a
    /// material that looks perfectly ordinary.
    func test_aRowWhoseMaterialDoesNotHashToItsKeyIsCalledDamaged() throws {
        let tool     = try makeCompilerNode()
        let material = try tool.buildCacheKeyMaterial(input: try makeInput())
        let entry    = ProcessCacheEntry(outputValues: [:], specTable: GraphSpecTable(inputWireSpecs: [:], rows: [:]),
                                         keyMaterial: material)
        let wrongKey = String(repeating: "b", count: 64)
        try engine.database.cacheEntry.save(hash: wrongKey, nodeType: material.nodeType, cost: 1,
                                            content: Data(try entry.toJSON().utf8), objects: [])

        let description = engine.cacheEntryDescription(key: wrongKey)

        XCTAssertTrue(description.contains("The entry is damaged."), "got: \(description)")
        XCTAssertTrue(description.contains(try material.cacheKey()),
                      "it names the key the material does account for, got: \(description)")
    }

    // MARK: - How an entry is stored

    /// B-107. The entry's JSON is stored as its own bytes in a blob column. GRDB encodes a
    /// `[UInt8]` field as JSON text of one decimal integer per byte, about 3.5 bytes on
    /// disk for each byte of entry; a `Data` field is a blob.
    func test_anEntryIsStoredAsABlobOfItsOwnBytes() throws {
        let key = try store(try makeCompilerNode(), input: try makeInput())
        let row = try XCTUnwrap(engine.database.cacheEntry.select(hash: key))

        let (type, length) = try engine.database.read { db in
            let sql = "SELECT typeof(content) AS type, length(content) AS length FROM CacheEntry WHERE hash = ?"
            let stored = try XCTUnwrap(Row.fetchOne(db, sql: sql, arguments: [key]))
            return (stored["type"] as String, stored["length"] as Int)
        }
        XCTAssertEqual(type, "blob")
        XCTAssertEqual(length, row.content.count, "one byte on disk for each byte of entry")
        XCTAssertEqual(row.content.first, UInt8(ascii: "{"), "the content is the entry's JSON itself")
    }
}
