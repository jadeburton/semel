//
//  MessageJSONTests.swift
//  SemelProtocolTests
//
//  The JSON text is the contract with a future peer, so representative messages are
//  asserted as exact text and not only by round trip. Keys are sorted, so the text is
//  stable across runs and the assertions can be literal.
//

@testable import SemelProtocol
import XCTest

final class MessageJSONTests: XCTestCase {

    // MARK: - Hello

    func test_encodesHelloAsRoleAndVersion() throws {
        let hello = Hello(protocolVersion: 1, role: .daemon)

        XCTAssertEqual(try json(hello), #"{"protocolVersion":1,"role":"daemon"}"#)
    }

    func test_encodesAcceptedHelloResponse() throws {
        let response = HelloResponse.accepted(serverVersion: "0.9", databasePath: "/tmp/graph.sqlite")

        XCTAssertEqual(try json(response),
                       #"{"accepted":{"databasePath":"\/tmp\/graph.sqlite","serverVersion":"0.9"}}"#)
    }

    func test_encodesRejectedHelloResponse() throws {
        let response = HelloResponse.rejected(reason: .versionMismatch(client: 1, server: 2))

        XCTAssertEqual(try json(response),
                       #"{"rejected":{"reason":{"versionMismatch":{"client":1,"server":2}}}}"#)
    }

    func test_roundTripsEveryHelloRejection() throws {
        let rejections: [HelloRejection] = [
            .versionMismatch(client: 1, server: 2),
            .roleNotOffered(role: .cache),
        ]
        for rejection in rejections {
            XCTAssertEqual(try roundTrip(HelloResponse.rejected(reason: rejection)),
                           .rejected(reason: rejection))
        }
    }

    /// Pinned so that a change to the message set is a change to this number too: the
    /// version is what lets a mismatched pair say so instead of misreading each other.
    func test_currentProtocolVersionIsTwentyFive() {
        XCTAssertEqual(ProtocolVersion.current, 25)
        XCTAssertEqual(Hello(role: .daemon).protocolVersion, 25,
                       "a hello sent with no version named speaks the current one")
    }

    /// B-95. The running list travels on every record, so a renderer that shows the
    /// active nodes needs nothing more on the wire.
    func test_encodesProgressEvent() throws {
        let record = ProgressRecord(scheduled: 12, computed: 3, fromCache: 4, pending: 5,
                                    running: [ActiveNode(type: "ClangCompiler", name: "input:/src/main.c")])
        XCTAssertEqual(try json(Event.daemon(.progress(record: record))),
                       #"{"daemon":{"progress":{"record":{"computed":3,"fromCache":4,"pending":5,"#
                     + #""running":[{"name":"input:\/src\/main.c","type":"ClangCompiler"}],"scheduled":12}}}}"#)
        XCTAssertEqual(try roundTrip(Event.daemon(.progress(record: record))), .daemon(.progress(record: record)))
    }

    func test_encodesSettledEvent() throws {
        XCTAssertEqual(try json(Event.daemon(.settled(scheduled: 12, computed: 3, fromCache: 9, errors: 0))),
                       #"{"daemon":{"settled":{"computed":3,"errors":0,"fromCache":9,"scheduled":12}}}"#)
    }

    func test_roundTripsSettledEvent() throws {
        let event = Event.daemon(.settled(scheduled: 12, computed: 3, fromCache: 9, errors: 1))

        XCTAssertEqual(try roundTrip(event), event)
    }

    func test_encodesArtifactsEvent() throws {
        let event = Event.daemon(.artifacts(appeared: ["output:/app"], changed: [], disappeared: ["output:/old"]))

        XCTAssertEqual(try json(event),
                       #"{"daemon":{"artifacts":{"appeared":["output:\/app"],"changed":[],"disappeared":["output:\/old"]}}}"#)
    }

    func test_roundTripsArtifactsEvent() throws {
        let event = Event.daemon(.artifacts(appeared: ["output:/app"],
                                            changed: ["output:/lib.a"],
                                            disappeared: ["output:/old"]))

        XCTAssertEqual(try roundTrip(event), event)
    }

    // MARK: - Daemon requests

    func test_encodesListRequestUnderItsRole() throws {
        let request = Request.daemon(.list(fileSystem: .input, pattern: "src/*.c"))

        XCTAssertEqual(try json(request),
                       #"{"daemon":{"list":{"fileSystem":"input","pattern":"src\/*.c"}}}"#)
    }

    /// The headers only: the bytes are in the frame body, and a header says how many of
    /// them are its file's.
    func test_encodesABatchOfFilesAsTheirHeaders() throws {
        let request = Request.daemon(.pushFiles(files: [PushedFileHeader(path: "src/a.c", mode: 0o644, length: 13)]))

        XCTAssertEqual(try json(request),
                       #"{"daemon":{"pushFiles":{"files":[{"length":13,"mode":420,"path":"src\/a.c"}]}}}"#)
    }

    /// One outcome per file, in the order sent, each saying what that file's own `pushFile`
    /// would have answered.
    func test_encodesWhatBecameOfEachFileOfABatch() throws {
        let response = DaemonResponse.pushFiles(outcomes: [.stored(didChange: false),
                                                           .failed(error: .nodeError(description: "boom"))])

        XCTAssertEqual(try json(response),
                       #"{"pushFiles":{"outcomes":[{"stored":{"didChange":false}},{"failed":{"error":{"nodeError":{"description":"boom"}}}}]}}"#)
    }

    func test_encodesAPayloadFreeRequestAsAnEmptyObject() throws {
        XCTAssertEqual(try json(Request.daemon(.nudge)), #"{"daemon":{"nudge":{}}}"#)
    }

    func test_encodesTheResetFlagUnderItsLabel() throws {
        XCTAssertEqual(try json(Request.daemon(.reset(clearCache: true))),
                       #"{"daemon":{"reset":{"clearCache":true}}}"#)
    }

    func test_encodesHelloRequestBesideTheRoles() throws {
        let request = Request.hello(Hello(protocolVersion: 1, role: .daemon))

        XCTAssertEqual(try json(request), #"{"hello":{"protocolVersion":1,"role":"daemon"}}"#)
    }

    func test_roundTripsEveryDaemonRequest() throws {
        let requests: [DaemonRequest] = [
            .list(fileSystem: .output, pattern: "**/*"),
            .beginBatch,
            .endBatch,
            .pushFile(path: "src/main.c", mode: 0o644),
            .pushFiles(files: [PushedFileHeader(path: "src/main.c", mode: 0o644, length: 13),
                               PushedFileHeader(path: "run.sh", mode: 0o755, length: 0)]),
            .pushFiles(files: []),
            .pushSymbolicLink(path: "Tiny.framework/Tiny", target: "Versions/Current/Tiny", referent: .file(mode: 0o755)),
            .pushSymbolicLink(path: "Tiny.framework/Versions/Current", target: "A", referent: .folder),
            .pushFolder(path: "src"),
            .contentRoots(path: "src"),
            .folderChildren(paths: ["src", "src/lib"]),
            .remove(pattern: "src/*.o"),
            .fetch(fileSystem: .output, path: "bin/app"),
            .errors(product: nil),
            .errors(product: "Packages/libModels.a"),
            .check,
            .collect,
            .tools(platform: "macos"),
            .reset(clearCache: false),
            .reset(clearCache: true),
            .nudge,
            .wait,
            .debug(cacheKey: nil),
            .debug(cacheKey: "285a5050ac7e8501af9c3bab064c1cf5432b67646d915ae3477fe816dced6419"),
            .explain(fileSystem: .output, path: "hello/hello"),
            .subscribe,
            .checkpoint(name: nil),
            .checkpoint(name: "before-update"),
            .checkpoints,
            .restore(name: "latest"),
        ]
        for request in requests {
            XCTAssertEqual(try roundTrip(Request.daemon(request)), .daemon(request))
        }
    }

    // MARK: - What a push compares (B-132)

    /// The records travel in a reply's body, typed: a folder's root and pin, and a child's
    /// hash, mode and link target, each under its own key and absent where it has none.
    func test_encodesWhatAPushComparesAsRecords() throws {
        let root   = HeldFolderRoot(path: "src/lib", contentRoot: "9f86d0", isPinned: true, hiddenFiles: [".env"])
        let marked = HeldFolderRoot(path: "src", contentRoot: nil, isPinned: true, hiddenFiles: [])
        let file   = HeldChild(name: "run.sh", kind: .file, contentHash: "abc", mode: 0o755, symbolicLinkTarget: nil,
                               isPinned: true)
        let link   = HeldChild(name: "Current", kind: .folder, contentHash: nil, mode: nil, symbolicLinkTarget: "A",
                               isPinned: true)

        XCTAssertEqual(try json(root), #"{"contentRoot":"9f86d0","hiddenFiles":[".env"],"isPinned":true,"path":"src\/lib"}"#)
        XCTAssertEqual(try json(marked), #"{"hiddenFiles":[],"isPinned":true,"path":"src"}"#)
        XCTAssertEqual(try json(file), #"{"contentHash":"abc","isPinned":true,"kind":"file","mode":493,"name":"run.sh"}"#)
        XCTAssertEqual(try json(link), #"{"isPinned":true,"kind":"folder","name":"Current","symbolicLinkTarget":"A"}"#)

        let folder = HeldFolder(path: "fw/Versions", children: [file, link])
        XCTAssertEqual(try MessageCoder.decode([HeldFolder].self, from: try MessageCoder.encode([folder])), [folder])
    }

    // MARK: - Daemon responses

    func test_encodesListEntryWithOptionalSizeAndMode() throws {
        let entry = ListEntry(path: "src/main.c", kind: .file, size: 120, mode: 0o644, status: .none)

        XCTAssertEqual(try json(entry),
                       #"{"kind":"file","mode":420,"path":"src\/main.c","size":120,"status":"none"}"#)
    }

    func test_omitsAbsentSizeAndModeFromListEntry() throws {
        let entry = ListEntry(path: "src", kind: .folder, size: nil, mode: nil, status: .deleted)

        XCTAssertEqual(try json(entry), #"{"kind":"folder","path":"src","status":"deleted"}"#)
    }

    /// The whole status vocabulary, as the words a peer decodes. A state added to or taken
    /// from this set is a change to the message set, and so to `ProtocolVersion.current`.
    func test_encodesEveryEntryStatusByItsOwnName() throws {
        let statuses: [EntryStatus] = [.none, .unreferenced, .pending, .notProduced, .deleted, .failed]

        let encoded = try statuses.map {
            try json(ListEntry(path: "a", kind: .file, size: nil, mode: nil, status: $0))
        }

        XCTAssertEqual(encoded, [
            #"{"kind":"file","path":"a","status":"none"}"#,
            #"{"kind":"file","path":"a","status":"unreferenced"}"#,
            #"{"kind":"file","path":"a","status":"pending"}"#,
            #"{"kind":"file","path":"a","status":"notProduced"}"#,
            #"{"kind":"file","path":"a","status":"deleted"}"#,
            #"{"kind":"file","path":"a","status":"failed"}"#,
        ])
    }

    /// A record carries the document its node published, decoded — every value of it under
    /// its own key — so a client renders it and reads no text the engine composed.
    func test_anErrorRecordCarriesTheDocumentItsNodePublished() throws {
        let record = Self.sampleRecord
        let decoded = try JSONDecoder().decode(ErrorRecord.self, from: try JSONEncoder().encode(record))

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.document.unpushedSource, nil)
        XCTAssertEqual(decoded.facts.nodeIDs, [12])

        let unpushed = ErrorRecord(document: .engine(.notPushed(path: "input:/clang.cfg", isFolder: false), subject: nil),
                                   products: [], facts: ErrorFacts(nodeType: "StaticFile", nodeIDs: [3], ports: ["output"],
                                                                   carrierCount: 1))
        XCTAssertEqual(try JSONDecoder().decode(ErrorRecord.self, from: try JSONEncoder().encode(unpushed)).document.unpushedSource,
                       "clang.cfg")
    }

    /// B-142. The products travel on every record, each under its own keys, and a record
    /// without the list is refused rather than read as a node that stops nothing.
    func test_anErrorRecordCarriesTheProductsItStops() throws {
        XCTAssertEqual(try json(StoppedProduct(path: "output:/app/Res/Assets.car", treeFolder: "output:/app/Res")),
                       #"{"path":"output:\/app\/Res\/Assets.car","treeFolder":"output:\/app\/Res"}"#)

        var withoutProducts = try XCTUnwrap(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(Self.sampleRecord))
                                            as? [String: Any])
        withoutProducts["products"] = nil
        XCTAssertThrowsError(try JSONDecoder().decode(ErrorRecord.self,
                                                      from: try JSONSerialization.data(withJSONObject: withoutProducts)))
    }

    /// A compile's failure, as a record carries it.
    static let sampleRecord = ErrorRecord(
        document: .tool(text: "input:/a.swift:1:1: error: boom", tool: "swiftc", status: 1, subject: .target(name: "A")),
        products: [StoppedProduct(path: "output:/app/bin"),
                   StoppedProduct(path: "output:/app/Res/Assets.car", treeFolder: "output:/app/Res")],
        facts: ErrorFacts(nodeType: "SwiftCompiler", nodeIDs: [12], ports: ["object", "swiftmodule"], carrierCount: 3))

    func test_roundTripsEveryDaemonResponse() throws {
        let record = Self.sampleRecord
        let descriptor = ToolDescriptorRecord(name: "swiftc", version: "6.0", platform: "macos",
                                              architecture: "arm64", machineSettings: ["sdk": "/x"])
        let responses: [DaemonResponse] = [
            .ok,
            .list(entries: [ListEntry(path: "a", kind: .file, size: 1, mode: 0o755, status: .pending)]),
            .pushFile(didChange: true),
            .pushFiles(outcomes: [.stored(didChange: true), .stored(didChange: false),
                                  .failed(error: .nodeError(description: "boom")),
                                  .failed(error: .pathNotFound(path: "src"))]),
            .contentRoots,
            .folderChildren,
            .remove(removedFiles: ["a", "b"], removedFolders: ["src"]),
            .fetch(mode: 0o644),
            .symbolicLink(target: "Versions/Current/Tiny"),
            .errors(records: [record]),
            .errors(records: [ErrorRecord(document: .engine(.unlinkedKind(kind: 43), subject: nil), products: [],
                                          facts: ErrorFacts(nodeType: "kind 43", nodeIDs: [37], ports: ["output"],
                                                            carrierCount: 1))]),
            .tools(namespaces: [ToolNamespaceRecord(namespace: "swift.compiler", toolName: "swiftc",
                                              descriptors: [descriptor])]),
            .reset(archivedGraphPath: "/tmp/semel-home/graph.sqlite.broken-2026-09-23T101500Z"),
            .reset(archivedGraphPath: nil),
            .debug,
            .check(scheduledNodes: 0),
            .check(scheduledNodes: 12),
            .collected(removed: 3, removedBytes: 4096, kept: 12),
            .explain(explanation: nil),
            .explain(explanation: Self.sampleExplanation),
            .checkpoint(name: "latest", contentRoot: "4d5d"),
            .checkpoints(entries: [CheckpointRecord(name: "latest", contentRoot: "4d5d")]),
            .checkpoints(entries: []),
            .restored(name: "latest", contentRoot: "4d5d", changedPaths: 3),
        ]
        for response in responses {
            XCTAssertEqual(try roundTrip(Response.daemon(response)), .daemon(response))
        }
    }

    /// B-91. A linker woken by one changed object and one that republished its value, and
    /// the compiler behind the changed one.
    private static let sampleExplanation = Explanation(
        nodes: [
            ExplainedNode(label: "ClangLinker #44", outcome: .computed, isNew: false,
                          causes: [ExplainedCause(port: "objects", wire: "hello2.o", change: .changed,
                                                  sourceLabel: "ClangCompiler #41", source: 1),
                                   ExplainedCause(port: "objects", wire: "main.o", change: .unchanged,
                                                  sourceLabel: "ClangCompiler #42", source: nil)],
                          unlistedCauses: 0),
            ExplainedNode(label: "ClangCompiler #41", outcome: .fromCache, isNew: true, causes: [],
                          unlistedCauses: 3),
        ],
        omittedNodes: 2, nodeLimit: 40, depthLimit: 16)

    /// The walk's answer is typed all the way down: outcomes and changes by name, sources
    /// by index, and a cause the walk did not follow with no index at all.
    func test_encodesTheExplainReplyAsRecords() throws {
        let explanation = Explanation(
            nodes: [ExplainedNode(label: "OutputFile #9 'output:/app'", outcome: .computed, isNew: false,
                                  causes: [ExplainedCause(port: "input", wire: "app", change: .unchanged,
                                                          sourceLabel: "ClangLinker #8", source: nil)],
                                  unlistedCauses: 0)],
            omittedNodes: 0, nodeLimit: 40, depthLimit: 16)

        XCTAssertEqual(try json(Response.daemon(.explain(explanation: explanation))),
                       #"{"daemon":{"explain":{"explanation":{"depthLimit":16,"nodeLimit":40,"nodes":[{"#
                     + #""causes":[{"change":"unchanged","port":"input","sourceLabel":"ClangLinker #8","wire":"app"}],"#
                     + #""isNew":false,"label":"OutputFile #9 'output:\/app'","outcome":"computed","unlistedCauses":0}],"#
                     + #""omittedNodes":0}}}}"#)
    }

    func test_encodesTheExplainRequestWithItsFileSystem() throws {
        XCTAssertEqual(try json(Request.daemon(.explain(fileSystem: .output, path: "hello/hello"))),
                       #"{"daemon":{"explain":{"fileSystem":"output","path":"hello\/hello"}}}"#)
    }

    /// The findings are the reply's *body*, so the reply itself carries only the count of
    /// scheduled nodes — a graph with a broken invariant per node would otherwise put the
    /// reply over the cap on a frame's JSON, in the one command that exists for a graph in
    /// that state.
    func test_encodesTheCheckReplyWithoutItsFindings() throws {
        XCTAssertEqual(try json(Response.daemon(.check(scheduledNodes: 12))),
                       #"{"daemon":{"check":{"scheduledNodes":12}}}"#)
    }

    func test_encodesACheckFindingAsKindSubjectAndSentence() throws {
        let finding = CheckFinding(kind: .productWithNoProducer,
                                   subject: "OutputFile #12 'output:/app'",
                                   sentence: "nothing is wired to its required input port 'input'")

        XCTAssertEqual(try json(finding),
                       #"{"kind":"productWithNoProducer","sentence":"nothing is wired to its required input port 'input'","subject":"OutputFile #12 'output:\/app'"}"#)
    }

    func test_roundTripsEveryCheckFindingKind() throws {
        let kinds: [CheckFinding.Kind] = [.danglingWire, .missingOutputPort, .staleIdentity, .unlinkedNodeType,
                                          .productWithNoProducer, .missingManifestChild,
                                          .errorWithoutMessage, .unreadableCacheKey,
                                          .graphCouldNotBeRead]
        for kind in kinds {
            let finding = CheckFinding(kind: kind, subject: "a", sentence: "b")
            XCTAssertEqual(try roundTrip([finding]), [finding])
        }
    }

    /// The graph's description is the reply's *body*, so the reply itself carries nothing
    /// and stays far under the cap on a frame's JSON however large the graph is.
    func test_encodesTheDebugReplyWithoutItsText() throws {
        XCTAssertEqual(try json(Response.daemon(.debug)), #"{"daemon":{"debug":{}}}"#)
    }

    func test_roundTripsEveryErrorResponse() throws {
        let errors: [ErrorResponse] = [
            .pathNotFound(path: "input:/nope"),
            .notAFolder(path: "input:/file"),
            .notAProduct(path: "output:/app"),
            .nodeError(description: "wire missing"),
            .roleNotOffered(role: .runner),
            .malformedRequest(description: "unknown case"),
            .replyTooLarge(request: "debug", bytes: 3_000_000, limit: 1_048_576),
            .unrecoverable(message: "object store is read-only"),
            .batchRejected(folder: "Dependencies/Pkg", lock: "Dependencies/Pkg.semel-lock",
                           expected: .contentRoot("4d5d"), found: "9e1f", paths: ["Dependencies/Pkg/a.swift"]),
            .batchRejected(folder: "Dependencies/Pkg", lock: "Dependencies/Pkg.semel-lock",
                           expected: .unreadable(line: 2, problem: "line 2: bogus"), found: nil, paths: []),
            .batchRejected(folder: "Dependencies/Pkg", lock: "Dependencies/Pkg.semel-lock",
                           expected: .otherFold(fold: "semel-folder-content-root 3", contentRoot: "4d5d"),
                           found: "9e1f", paths: []),
            .checkpointNotFound(name: "nope", known: ["latest"]),
        ]
        for error in errors {
            XCTAssertEqual(try roundTrip(Response.error(error)), .error(error))
        }
    }

    func test_encodesListResponseUnderItsRole() throws {
        let response = Response.daemon(.list(entries: [ListEntry(path: "a", kind: .file, size: 1, mode: nil, status: .none)]))

        XCTAssertEqual(try json(response),
                       #"{"daemon":{"list":{"entries":[{"kind":"file","path":"a","size":1,"status":"none"}]}}}"#)
    }

    func test_encodesErrorResponseAtTheRoot() throws {
        let response = Response.error(.pathNotFound(path: "input:/x"))

        XCTAssertEqual(try json(response), #"{"error":{"pathNotFound":{"path":"input:\/x"}}}"#)
    }

    func test_roundTripsHelloResponseAtTheRoot() throws {
        let response = Response.hello(.accepted(serverVersion: "1", databasePath: "/g"))

        XCTAssertEqual(try roundTrip(response), response)
    }

    // MARK: - Events

    func test_encodesNoticeEvent() throws {
        XCTAssertEqual(try json(Event.daemon(.notice(line: "output:/app: written"))),
                       #"{"daemon":{"notice":{"line":"output:\/app: written"}}}"#)
    }

    func test_roundTripsErrorsEvent() throws {
        let event = Event.daemon(.errors(records: [Self.sampleRecord]))

        XCTAssertEqual(try roundTrip(event), event)
    }

    // MARK: - Decoding what we do not know

    /// A peer built against a newer message set will send cases this build has never
    /// heard of. That must decode as an error, not crash, so the server can answer it.
    func test_decodingAnUnknownCaseThrows() {
        let data = Data(#"{"daemon":{"teleport":{}}}"#.utf8)

        XCTAssertThrowsError(try MessageCoder.decode(Request.self, from: data))
    }

    /// `allKeys` on a strict container only lists keys that convert to its `CodingKeys`, so
    /// this must be checked against the raw JSON keys, not just the typed ones, or an empty
    /// object would be reported as having none of the keys that were actually absent.
    func test_decodingZeroRoleKeysNamesAnEmptyList() {
        let data = Data("{}".utf8)

        XCTAssertThrowsError(try MessageCoder.decode(Request.self, from: data)) { error in
            XCTAssertTrue(String(describing: error).contains("found []"), String(describing: error))
        }
    }

    /// A role this build does not have a `CodingKeys` case for (`cache` is a `Role`, but not
    /// yet a message-set root) must still be named in the error, not silently dropped from
    /// `found`.
    func test_decodingAnUnknownRoleKeyNamesIt() {
        let data = Data(#"{"cache":{}}"#.utf8)

        XCTAssertThrowsError(try MessageCoder.decode(Request.self, from: data)) { error in
            let message = Self.decodingMessage(of: error)
            XCTAssertTrue(message.contains(#"["cache"]"#), message)
        }
    }

    /// A known role beside an unknown one must not decode silently as the known role; both
    /// keys belong in the error, sorted so the message is stable.
    func test_decodingAKnownRoleBesideAnUnknownOneNamesBoth() {
        let data = Data(#"{"daemon":{"nudge":{}},"cache":{}}"#.utf8)

        XCTAssertThrowsError(try MessageCoder.decode(Request.self, from: data)) { error in
            let message = Self.decodingMessage(of: error)
            XCTAssertTrue(message.contains(#"["cache", "daemon"]"#), message)
        }
    }

    /// The decoder's own sentence. `String(describing:)` of a `DecodingError` quotes that
    /// sentence, and whether the quotes inside it are escaped differs between Swift
    /// toolchains, so a test that reads the sentence goes to the context it is stored in.
    private static func decodingMessage(of error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return String(describing: error)
        }
        switch decodingError {
        case .dataCorrupted(let context),
             .keyNotFound(_, let context),
             .typeMismatch(_, let context),
             .valueNotFound(_, let context):
            return context.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }

    // MARK: - Helpers

    func json<Message: Encodable>(_ message: Message) throws -> String {
        String(decoding: try MessageCoder.encode(message), as: UTF8.self)
    }

    func roundTrip<Message: Codable>(_ message: Message) throws -> Message {
        try MessageCoder.decode(Message.self, from: try MessageCoder.encode(message))
    }
}
