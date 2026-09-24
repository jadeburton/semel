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
    func test_currentProtocolVersionIsSeven() {
        XCTAssertEqual(ProtocolVersion.current, 7)
        XCTAssertEqual(Hello(role: .daemon).protocolVersion, 7, "a hello sent with no version named speaks the current one")
    }

    func test_encodesSettledEvent() throws {
        XCTAssertEqual(try json(Event.daemon(.settled(scheduled: 12, computed: 3, fromCache: 9, errors: 0))),
                       #"{"daemon":{"settled":{"computed":3,"errors":0,"fromCache":9,"scheduled":12}}}"#)
    }

    func test_roundTripsSettledEvent() throws {
        let event = Event.daemon(.settled(scheduled: 12, computed: 3, fromCache: 9, errors: 1))

        XCTAssertEqual(try roundTrip(event), event)
    }

    // MARK: - Daemon requests

    func test_encodesListRequestUnderItsRole() throws {
        let request = Request.daemon(.list(fileSystem: .input, pattern: "src/*.c"))

        XCTAssertEqual(try json(request),
                       #"{"daemon":{"list":{"fileSystem":"input","pattern":"src\/*.c"}}}"#)
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
            .pushFolder(path: "src"),
            .remove(pattern: "src/*.o"),
            .fetch(fileSystem: .output, path: "bin/app"),
            .errors,
            .check,
            .tools,
            .reset(clearCache: false),
            .reset(clearCache: true),
            .nudge,
            .wait,
            .debug,
            .subscribe,
        ]
        for request in requests {
            XCTAssertEqual(try roundTrip(Request.daemon(request)), .daemon(request))
        }
    }

    // MARK: - Daemon responses

    func test_encodesListEntryWithOptionalSizeAndMode() throws {
        let entry = ListEntry(path: "src/main.c", kind: .file, size: 120, mode: 0o644, status: .none)

        XCTAssertEqual(try json(entry),
                       #"{"kind":"file","mode":420,"path":"src\/main.c","size":120,"status":"none"}"#)
    }

    func test_omitsAbsentSizeAndModeFromListEntry() throws {
        let entry = ListEntry(path: "src", kind: .folder, size: nil, mode: nil, status: .missing)

        XCTAssertEqual(try json(entry), #"{"kind":"folder","path":"src","status":"missing"}"#)
    }

    func test_roundTripsEveryDaemonResponse() throws {
        let record = ErrorRecord(label: "SwiftCompiler  'input:/a.swift'",
                                 entries: [ErrorEntry(ports: ["output", "errorLog"], message: "boom")])
        let descriptor = ToolDescriptorRecord(name: "swiftc", version: "6.0", platform: "macos",
                                              architecture: "arm64", machineSettings: ["sdk": "/x"])
        let responses: [DaemonResponse] = [
            .ok,
            .list(entries: [ListEntry(path: "a", kind: .file, size: 1, mode: 0o755, status: .pending)]),
            .pushFile(didChange: true),
            .remove(removedFiles: ["a", "b"], removedFolders: ["src"]),
            .fetch(mode: 0o644),
            .errors(records: [record]),
            .tools(namespaces: [ToolNamespaceRecord(namespace: "swift.compiler", toolName: "swiftc",
                                              descriptors: [descriptor])]),
            .reset(archivedGraphPath: "/tmp/semel-home/graph.sqlite.broken-2026-09-23T101500Z"),
            .reset(archivedGraphPath: nil),
            .debug,
            .check,
        ]
        for response in responses {
            XCTAssertEqual(try roundTrip(Response.daemon(response)), .daemon(response))
        }
    }

    /// The findings are the reply's *body*, so the reply itself carries nothing — a graph
    /// with a broken invariant per node would otherwise put the reply over the cap on a
    /// frame's JSON, in the one command that exists for a graph in that state.
    func test_encodesTheCheckReplyWithoutItsFindings() throws {
        XCTAssertEqual(try json(Response.daemon(.check)), #"{"daemon":{"check":{}}}"#)
    }

    func test_encodesACheckFindingAsKindSubjectAndSentence() throws {
        let finding = CheckFinding(kind: .productWithNoProducer,
                                   subject: "OutputFile #12 'output:/app'",
                                   sentence: "nothing is wired to its required input port 'input'")

        XCTAssertEqual(try json(finding),
                       #"{"kind":"productWithNoProducer","sentence":"nothing is wired to its required input port 'input'","subject":"OutputFile #12 'output:\/app'"}"#)
    }

    func test_roundTripsEveryCheckFindingKind() throws {
        let kinds: [CheckFinding.Kind] = [.danglingWire, .unreadableGraphSpec, .unlinkedNodeType,
                                          .productWithNoProducer, .missingManifestChild,
                                          .errorWithoutMessage, .unreadableCacheKey]
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
            .nodeError(description: "wire missing"),
            .roleNotOffered(role: .runner),
            .malformedRequest(description: "unknown case"),
            .replyTooLarge(request: "debug", bytes: 3_000_000, limit: 1_048_576),
            .unrecoverable(message: "object store is read-only"),
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
        let event = Event.daemon(.errors(records: [ErrorRecord(label: "x", entries: [])]))

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
