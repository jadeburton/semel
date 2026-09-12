# SemelProtocol Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 1 of the daemon split: a new dependency-free SwiftPM package, `SemelProtocol`, holding the frame codec and every message that will cross the socket between `semel` and `semelserv`.

**Architecture:** A 24-byte binary frame header carries a JSON section and a raw body. Three Codable enums (`Request`, `Response`, `Event`) are grouped by role, with the daemon role fully defined and room for the cache and runner roles. Nothing else in the repository changes except the workspace file and the build instructions.

**Tech Stack:** Swift 5.9, SwiftPM, Foundation only, XCTest. macOS 13 floor.

**Spec:** `docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md` — read Section 1 before starting; the rest is context for why.

## Global Constraints

- `swift-tools-version: 5.9`, `platforms: [.macOS(.v13)]`, matching every other package.
- `SemelProtocol` imports **Foundation only**. No `SemelNodeKit`, no `SemelDatabaseModels`, no GRDB. Paths, hashes and modes are `String`, `UInt16` and `Int`.
- Frame header is 24 bytes, all integers big-endian, layout exactly as in spec Section 1.
- `maximumJSONLength` = 1 MB (`1 << 20`), `maximumBodyLength` = 512 MB (`512 << 20`). Checked before allocation.
- Formatting: four spaces, brace on the declaration line, no `else if` chains (use a nested block or a `switch`), columns aligned where it aids reading, `// MARK: -` in any file long enough to navigate. US-English spelling in comments.
- Naming: no single-character names, words spelt out, `struct` unless reference semantics are needed, `internal` by default.
- Errors are enums with associated values carrying enough context to act on.
- Tests: XCTest, `final class XTests: XCTestCase`, methods named `test_whatItDoes`. No `SemelCoreTestCase` here — this package has no process globals to isolate.
- File header comment style: `// FileName.swift` / `// SemelProtocol` then a blank comment line and a short paragraph on what the file is for. `///` doc comments explain *why*, not what.
- Commit messages are sentences in the imperative, no conventional-commit prefixes. End each with the two attribution lines given in this session.
- Run `swift test --package-path SemelProtocol` from the repository root (`semel/`). Do not run the other suites for this plan; nothing they cover changes.

---

## File structure

```
SemelProtocol/
  Package.swift
  Sources/SemelProtocol/
    Frame.swift             Frame, FrameKind, FrameError, limits and header constants
    FrameEncoder.swift      Frame → Data
    FrameDecoder.swift      incremental Data → Frame
    MessageCoder.swift      the one JSONEncoder/JSONDecoder configuration
    Hello.swift             Role, ProtocolVersion, Hello, HelloResponse, HelloRejection
    DaemonMessages.swift    DaemonRequest, DaemonResponse, DaemonEvent and their record types
    Messages.swift          Request, Response, Event, ErrorResponse (the role-grouped roots)
    Frame+Messages.swift    building a Frame from a message and reading one back
  Tests/
    FrameEncoderTests.swift
    FrameDecoderTests.swift
    MessageJSONTests.swift  exact JSON text of representative messages, and round trips
    FrameMessageTests.swift end to end: message → frame → bytes → frame → message
```

The JSON shape is pinned by tests that assert exact text, because a wire format is a contract with a future peer, and Swift's synthesized Codable for enums is the contract: a case with labelled associated values encodes as `{"caseName":{"label":value,…}}`, a case with none as `{"caseName":{}}`, a nil optional field is omitted, and an *unlabelled* value is keyed `_0`. So every associated value in the role enums is **labelled**, and the three root enums (`Request`, `Response`, `Event`), whose payloads are single values with no natural field name, hand-write their Codable so the envelope is `{"daemon":{"list":…}}` with nothing in between. This refines the spec's "each payload is its own struct": a labelled associated value isolates a case's fields just as well and reads better as JSON. (Verified against Swift 5.9's synthesis before this plan was written.)

---

### Task 1: Package scaffold and the frame value

**Files:**
- Create: `SemelProtocol/Package.swift`
- Create: `SemelProtocol/Sources/SemelProtocol/Frame.swift`
- Create: `SemelProtocol/Sources/SemelProtocol/FrameEncoder.swift`
- Create: `SemelProtocol/Tests/FrameEncoderTests.swift`
- Modify: `Semel.xcworkspace/contents.xcworkspacedata`
- Modify: `AGENTS.md` (the "Build and test" block)

**Interfaces:**
- Produces: `Frame`, `FrameKind`, `FrameError`, `FrameEncoder.encode(_:) -> Data`, the constants `Frame.version`, `Frame.headerLength`, `Frame.maximumJSONLength`, `Frame.maximumBodyLength`.

- [ ] **Step 1: Create the package manifest**

`SemelProtocol/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

// Everything that crosses the wire between `semel` and `semelserv`, and nothing else.
//
// It deliberately depends on Foundation alone. Anything the engine wants to send is
// mirrored here and mapped in `SemelServ`, never imported, so the wire format stays
// independent of the persisted schema and a client that speaks one role does not link the
// database. See docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md.
let package = Package(
    name: "SemelProtocol",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelProtocol", targets: ["SemelProtocol"]),
    ],
    targets: [
        .target(
            name: "SemelProtocol",
            path: "Sources/SemelProtocol"
        ),
        .testTarget(
            name: "SemelProtocolTests",
            dependencies: ["SemelProtocol"],
            path: "Tests"
        ),
    ]
)
```

- [ ] **Step 2: Write the failing encoder test**

`SemelProtocol/Tests/FrameEncoderTests.swift`:

```swift
//
//  FrameEncoderTests.swift
//  SemelProtocolTests
//
//  The header layout is the contract with every future peer, so it is asserted byte by
//  byte rather than only by round trip: a round trip would pass if both ends made the
//  same mistake.
//

@testable import SemelProtocol
import XCTest

final class FrameEncoderTests: XCTestCase {

    func test_encodesHeaderFieldsBigEndianInSpecifiedOrder() {
        let frame = Frame(kind:          .response,
                          correlationID: 0x0102030405060708,
                          json:          Data("{}".utf8),
                          body:          Data([0xAA, 0xBB, 0xCC]))

        let bytes = [UInt8](FrameEncoder.encode(frame))

        XCTAssertEqual(bytes.count, Frame.headerLength + 2 + 3)
        XCTAssertEqual(bytes[0], Frame.version)
        XCTAssertEqual(bytes[1], FrameKind.response.rawValue)
        XCTAssertEqual(bytes[2], 0)                                        // flags
        XCTAssertEqual(bytes[3], 0)                                        // reserved
        XCTAssertEqual(Array(bytes[4..<12]),  [1, 2, 3, 4, 5, 6, 7, 8])    // correlationID
        XCTAssertEqual(Array(bytes[12..<16]), [0, 0, 0, 2])                // jsonLength
        XCTAssertEqual(Array(bytes[16..<24]), [0, 0, 0, 0, 0, 0, 0, 3])    // bodyLength
        XCTAssertEqual(Array(bytes[24..<26]), [UInt8]("{}".utf8))
        XCTAssertEqual(Array(bytes[26..<29]), [0xAA, 0xBB, 0xCC])
    }

    func test_encodesEmptySectionsAsHeaderOnly() {
        let frame = Frame(kind: .event, correlationID: 0, json: Data(), body: Data())

        XCTAssertEqual(FrameEncoder.encode(frame).count, Frame.headerLength)
    }

    func test_bodyDefaultsToEmpty() {
        let frame = Frame(kind: .request, correlationID: 7, json: Data("{}".utf8))

        XCTAssertEqual(frame.body, Data())
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path SemelProtocol`
Expected: compile failure, `cannot find 'Frame' in scope`.

- [ ] **Step 4: Write the frame value**

`SemelProtocol/Sources/SemelProtocol/Frame.swift`:

```swift
// Frame.swift
// SemelProtocol
//
// The unit of transmission. Every frame carries a JSON section and a raw body, either of
// which may be empty, so that a message with bytes attached (a pushed file, a fetched
// artifact) is one frame rather than two tied by correlation ID with the failure mode of
// one arriving without the other.
//
//   offset  size  field
//     0      1    version
//     1      1    kind            1=request 2=response 3=event
//     2      1    flags           reserved (chunking, compression)
//     3      1    reserved
//     4      8    correlationID   echoed in the response; 0 for events
//    12      4    jsonLength
//    16      8    bodyLength
//    24      …    json bytes
//     …      …    body bytes
//
// All integers big-endian. No magic bytes: the transport already gives ordered,
// integrity-checked delivery, and a desync would be our own framing bug. The message type
// is not in the header either — it is the enum case inside the JSON, and a second
// discriminator would be two sources of truth for one question.

import Foundation

public enum FrameKind: UInt8 {
    case request  = 1
    case response = 2
    case event    = 3
}

public struct Frame: Equatable {

    /// Governs *framing* and is checked before anything is decoded. A mismatch closes the
    /// connection, because nothing further can be trusted. The message set has its own
    /// version, negotiated in `Hello` once framing is known to work.
    public static let version: UInt8 = 1

    public static let headerLength = 24

    /// Enforced by the decoder before allocation, so a corrupt or hostile length cannot
    /// ask for memory the process does not have.
    public static let maximumJSONLength: UInt32 = 1 << 20
    public static let maximumBodyLength: UInt64 = 512 << 20

    public let kind:          FrameKind
    public let correlationID: UInt64
    public let json:          Data
    public let body:          Data

    public init(kind: FrameKind, correlationID: UInt64, json: Data, body: Data = Data()) {
        self.kind          = kind
        self.correlationID = correlationID
        self.json          = json
        self.body          = body
    }
}

public enum FrameError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(UInt8)
    case unknownKind(UInt8)
    case jsonTooLarge(declared: UInt32, limit: UInt32)
    case bodyTooLarge(declared: UInt64, limit: UInt64)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "frame version \(version) is not supported; this end speaks version \(Frame.version)"
        case .unknownKind(let kind):
            return "frame kind \(kind) is not request, response or event"
        case .jsonTooLarge(let declared, let limit):
            return "frame declares \(declared) bytes of JSON; the limit is \(limit)"
        case .bodyTooLarge(let declared, let limit):
            return "frame declares \(declared) bytes of body; the limit is \(limit)"
        }
    }
}
```

- [ ] **Step 5: Write the encoder**

`SemelProtocol/Sources/SemelProtocol/FrameEncoder.swift`:

```swift
// FrameEncoder.swift
// SemelProtocol
//
// Frame → bytes. The layout is documented on `Frame`.

import Foundation

public enum FrameEncoder {

    public static func encode(_ frame: Frame) -> Data {
        var bytes = Data(capacity: Frame.headerLength + frame.json.count + frame.body.count)

        bytes.append(Frame.version)
        bytes.append(frame.kind.rawValue)
        bytes.append(0)     // flags
        bytes.append(0)     // reserved
        bytes.appendBigEndian(frame.correlationID)
        bytes.appendBigEndian(UInt32(frame.json.count))
        bytes.appendBigEndian(UInt64(frame.body.count))
        bytes.append(frame.json)
        bytes.append(frame.body)

        return bytes
    }
}

extension Data {

    /// Most-significant byte first, whatever the host's byte order.
    mutating func appendBigEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path SemelProtocol`
Expected: 3 tests pass.

- [ ] **Step 7: Add the package to the workspace and the build instructions**

In `Semel.xcworkspace/contents.xcworkspacedata`, add after the `SemelNodeKit` entry:

```xml
   <FileRef
      location = "group:SemelProtocol">
   </FileRef>
```

In `AGENTS.md`, the "Build and test" block lists one `swift test` line per package. Add after the `SemelNodeKit` line:

```sh
swift test --package-path SemelProtocol       # the wire protocol (frame codec + messages)
```

and change the sentence "Run all five." to "Run all six."

- [ ] **Step 8: Commit**

```bash
git add SemelProtocol Semel.xcworkspace/contents.xcworkspacedata AGENTS.md
git commit -m "Add the SemelProtocol package with the frame value and encoder

Phase 1 of the local daemon split. The package depends on Foundation
alone; the header layout is asserted byte by byte.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 2: The incremental frame decoder

**Files:**
- Create: `SemelProtocol/Sources/SemelProtocol/FrameDecoder.swift`
- Create: `SemelProtocol/Tests/FrameDecoderTests.swift`

**Interfaces:**
- Consumes: `Frame`, `FrameKind`, `FrameError`, `FrameEncoder.encode(_:)` from Task 1.
- Produces: `struct FrameDecoder` with `init()`, `mutating func append(_ bytes: Data)`, `mutating func next() throws -> Frame?`.

- [ ] **Step 1: Write the failing decoder tests**

`SemelProtocol/Tests/FrameDecoderTests.swift`:

```swift
//
//  FrameDecoderTests.swift
//  SemelProtocolTests
//
//  A socket delivers whatever it delivers: half a header, three frames at once, a body
//  split across reads. The decoder has to be happy with all of it, and it has to refuse
//  an over-limit length before allocating anything, because a declared length is the one
//  field a corrupt or hostile peer controls directly.
//

@testable import SemelProtocol
import XCTest

final class FrameDecoderTests: XCTestCase {

    private let sample = Frame(kind:          .request,
                               correlationID: 42,
                               json:          Data(#"{"hello":{}}"#.utf8),
                               body:          Data([1, 2, 3, 4, 5]))

    // MARK: - Whole frames

    func test_roundTripsAFrame() throws {
        var decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(sample))

        XCTAssertEqual(try decoder.next(), sample)
        XCTAssertNil(try decoder.next())
    }

    func test_roundTripsAHeaderOnlyFrame() throws {
        let empty = Frame(kind: .event, correlationID: 0, json: Data(), body: Data())
        var decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(empty))

        XCTAssertEqual(try decoder.next(), empty)
    }

    func test_yieldsTwoFramesFromOneAppend() throws {
        let second = Frame(kind: .response, correlationID: 43, json: Data("{}".utf8))
        var decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(sample) + FrameEncoder.encode(second))

        XCTAssertEqual(try decoder.next(), sample)
        XCTAssertEqual(try decoder.next(), second)
        XCTAssertNil(try decoder.next())
    }

    // MARK: - Partial delivery

    func test_waitsWhenHeaderIsIncomplete() throws {
        var decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(sample).prefix(Frame.headerLength - 1))

        XCTAssertNil(try decoder.next())
    }

    func test_waitsWhenBodyIsIncomplete() throws {
        let bytes = FrameEncoder.encode(sample)
        var decoder = FrameDecoder()
        decoder.append(bytes.prefix(bytes.count - 1))

        XCTAssertNil(try decoder.next())
    }

    func test_assemblesAFrameDeliveredOneByteAtATime() throws {
        var decoder = FrameDecoder()
        for byte in FrameEncoder.encode(sample) {
            XCTAssertNil(try decoder.next())
            decoder.append(Data([byte]))
        }

        XCTAssertEqual(try decoder.next(), sample)
    }

    // MARK: - Rejection, before allocation

    func test_rejectsAnUnsupportedVersion() {
        var bytes = FrameEncoder.encode(sample)
        bytes[0] = Frame.version + 1
        var decoder = FrameDecoder()
        decoder.append(bytes)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameError, .unsupportedVersion(Frame.version + 1))
        }
    }

    func test_rejectsAnUnknownKind() {
        var bytes = FrameEncoder.encode(sample)
        bytes[1] = 9
        var decoder = FrameDecoder()
        decoder.append(bytes)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameError, .unknownKind(9))
        }
    }

    /// Only the header is present, so a decoder that waited for the declared bytes before
    /// checking the limit would wait forever — or, worse, reserve room for them.
    func test_rejectsAnOversizedJSONLengthFromTheHeaderAlone() {
        var bytes = FrameEncoder.encode(sample).prefix(Frame.headerLength)
        let declared = Frame.maximumJSONLength + 1
        bytes.replaceSubrange(12..<16, with: bigEndianBytes(of: declared))
        var decoder = FrameDecoder()
        decoder.append(bytes)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameError,
                           .jsonTooLarge(declared: declared, limit: Frame.maximumJSONLength))
        }
    }

    func test_rejectsAnOversizedBodyLengthFromTheHeaderAlone() {
        var bytes = FrameEncoder.encode(sample).prefix(Frame.headerLength)
        let declared = Frame.maximumBodyLength + 1
        bytes.replaceSubrange(16..<24, with: bigEndianBytes(of: declared))
        var decoder = FrameDecoder()
        decoder.append(bytes)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameError,
                           .bodyTooLarge(declared: declared, limit: Frame.maximumBodyLength))
        }
    }

    func test_acceptsALengthExactlyAtTheLimit() throws {
        let json = Data(repeating: UInt8(ascii: " "), count: Int(Frame.maximumJSONLength))
        let frame = Frame(kind: .request, correlationID: 1, json: json)
        var decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(frame))

        XCTAssertEqual(try decoder.next()?.json.count, Int(Frame.maximumJSONLength))
    }

    // MARK: - Helpers

    private func bigEndianBytes<Integer: FixedWidthInteger>(of value: Integer) -> Data {
        var data = Data()
        data.appendBigEndian(value)
        return data
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path SemelProtocol`
Expected: compile failure, `cannot find 'FrameDecoder' in scope`.

- [ ] **Step 3: Write the decoder**

`SemelProtocol/Sources/SemelProtocol/FrameDecoder.swift`:

```swift
// FrameDecoder.swift
// SemelProtocol
//
// Bytes → frames, incrementally. Feed it whatever the transport delivered and ask for the
// next complete frame; it answers nil until one is whole.
//
// The header is validated the moment it is complete, before the JSON and body bytes have
// arrived. That ordering is the point: a declared length is checked against the limit
// while it is still just a number, never after it has been used to reserve memory.

import Foundation

public struct FrameDecoder {

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(contentsOf: bytes)
    }

    /// The next complete frame, or nil if more bytes are needed. Throws on a header that
    /// can never become a valid frame; the caller should close the connection, since
    /// nothing after a bad header can be trusted.
    public mutating func next() throws -> Frame? {
        guard buffer.count >= Frame.headerLength else {
            return nil
        }

        let version = buffer[0]
        guard version == Frame.version else {
            throw FrameError.unsupportedVersion(version)
        }

        guard let kind = FrameKind(rawValue: buffer[1]) else {
            throw FrameError.unknownKind(buffer[1])
        }

        let correlationID = readBigEndian(UInt64.self, at: 4)
        let jsonLength    = readBigEndian(UInt32.self, at: 12)
        let bodyLength    = readBigEndian(UInt64.self, at: 16)

        guard jsonLength <= Frame.maximumJSONLength else {
            throw FrameError.jsonTooLarge(declared: jsonLength, limit: Frame.maximumJSONLength)
        }
        guard bodyLength <= Frame.maximumBodyLength else {
            throw FrameError.bodyTooLarge(declared: bodyLength, limit: Frame.maximumBodyLength)
        }

        let jsonStart = Frame.headerLength
        let bodyStart = jsonStart + Int(jsonLength)
        let frameEnd  = bodyStart + Int(bodyLength)

        guard buffer.count >= frameEnd else {
            return nil
        }

        let frame = Frame(kind:          kind,
                          correlationID: correlationID,
                          json:          Data(buffer[jsonStart..<bodyStart]),
                          body:          Data(buffer[bodyStart..<frameEnd]))

        buffer.removeFirst(frameEnd)
        return frame
    }

    private func readBigEndian<Integer: FixedWidthInteger>(_ type: Integer.Type, at offset: Int) -> Integer {
        var value: Integer = 0
        for index in 0..<MemoryLayout<Integer>.size {
            value = value << 8 | Integer(buffer[offset + index])
        }
        return value
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path SemelProtocol`
Expected: all tests pass (3 encoder + 11 decoder).

- [ ] **Step 5: Commit**

```bash
git add SemelProtocol
git commit -m "Decode frames incrementally, rejecting bad headers before allocation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 3: The JSON coder and the Hello handshake

**Files:**
- Create: `SemelProtocol/Sources/SemelProtocol/MessageCoder.swift`
- Create: `SemelProtocol/Sources/SemelProtocol/Hello.swift`
- Create: `SemelProtocol/Tests/MessageJSONTests.swift`

**Interfaces:**
- Produces: `MessageCoder.encode(_:) throws -> Data`, `MessageCoder.decode(_:from:) throws -> T`; `Role`, `ProtocolVersion.current`, `Hello`, `HelloRejection`, `HelloResponse`.

- [ ] **Step 1: Write the failing tests**

`SemelProtocol/Tests/MessageJSONTests.swift`:

```swift
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

    func test_currentProtocolVersionIsOne() {
        XCTAssertEqual(ProtocolVersion.current, 1)
    }

    // MARK: - Helpers

    func json<Message: Encodable>(_ message: Message) throws -> String {
        String(decoding: try MessageCoder.encode(message), as: UTF8.self)
    }

    func roundTrip<Message: Codable>(_ message: Message) throws -> Message {
        try MessageCoder.decode(Message.self, from: try MessageCoder.encode(message))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path SemelProtocol`
Expected: compile failure, `cannot find 'Hello' in scope`.

- [ ] **Step 3: Write the coder**

`SemelProtocol/Sources/SemelProtocol/MessageCoder.swift`:

```swift
// MessageCoder.swift
// SemelProtocol
//
// The one JSON configuration both ends use. Keys are sorted so that the same message
// always produces the same bytes — which is what lets a test assert the wire text
// literally, and what will let a cache key over a message be stable if one is ever wanted.

import Foundation

public enum MessageCoder {

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    public static func encode<Message: Encodable>(_ message: Message) throws -> Data {
        try encoder.encode(message)
    }

    public static func decode<Message: Decodable>(_ type: Message.Type, from data: Data) throws -> Message {
        try decoder.decode(type, from: data)
    }
}
```

- [ ] **Step 4: Write the handshake types**

`SemelProtocol/Sources/SemelProtocol/Hello.swift`:

```swift
// Hello.swift
// SemelProtocol
//
// The first exchange on every connection. The client names the role it wants and the
// message-set version it speaks; the server accepts or says why not.
//
// This is a second version field on purpose. `Frame.version` governs framing and a
// mismatch there closes the connection, because nothing further can be trusted.
// `protocolVersion` governs the message set and is negotiated once framing is known to
// work, so a mismatch can be reported as a clean rejection with both numbers in it.

import Foundation

/// One `semelserv` binary, several modes. A server offers some subset; a client asks for
/// one. Only `daemon` has messages today; the others are named so that `Hello` does not
/// change when they arrive.
public enum Role: String, Codable, Equatable {
    case daemon
    case cache
    case runner
}

public enum ProtocolVersion {
    public static let current = 1
}

public struct Hello: Codable, Equatable {
    public let protocolVersion: Int
    public let role:            Role

    public init(protocolVersion: Int = ProtocolVersion.current, role: Role) {
        self.protocolVersion = protocolVersion
        self.role            = role
    }
}

public enum HelloRejection: Codable, Equatable {
    case versionMismatch(client: Int, server: Int)
    case roleNotOffered(role: Role)
}

public enum HelloResponse: Codable, Equatable {
    /// `databasePath` is here because the REPL prints "Graph: …" at startup from local
    /// state today, and after the split the client has no such state.
    case accepted(serverVersion: String, databasePath: String)
    case rejected(reason: HelloRejection)
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path SemelProtocol`
Expected: all tests pass. If the `accepted` assertion fails on `\/` escaping, keep the test's expectation: Foundation's `JSONEncoder` escapes forward slashes unless `.withoutEscapingSlashes` is set, and we do not set it, so the literal in the test must contain `\/`.

- [ ] **Step 6: Commit**

```bash
git add SemelProtocol
git commit -m "Add the message coder and the Hello handshake

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 4: The daemon role's messages and the role-grouped roots

**Files:**
- Create: `SemelProtocol/Sources/SemelProtocol/DaemonMessages.swift`
- Create: `SemelProtocol/Sources/SemelProtocol/Messages.swift`
- Modify: `SemelProtocol/Tests/MessageJSONTests.swift`

**Interfaces:**
- Consumes: `MessageCoder`, `Hello`, `HelloResponse`, `Role` from Task 3.
- Produces: `FileSystemName`, `EntryKind`, `EntryStatus`, `ListEntry`, `ErrorEntry`, `ErrorRecord`, `ToolDescriptorRecord`, `ToolNamespace`, `DaemonRequest`, `DaemonResponse`, `DaemonEvent`, `ErrorResponse`, `Request`, `Response`, `Event`.

- [ ] **Step 1: Add the failing tests**

Append to `MessageJSONTests`, before `// MARK: - Helpers`:

```swift
    // MARK: - Daemon requests

    func test_encodesListRequestUnderItsRole() throws {
        let request = Request.daemon(.list(fileSystem: .input, pattern: "src/*.c"))

        XCTAssertEqual(try json(request),
                       #"{"daemon":{"list":{"fileSystem":"input","pattern":"src\/*.c"}}}"#)
    }

    func test_encodesAPayloadFreeRequestAsAnEmptyObject() throws {
        XCTAssertEqual(try json(Request.daemon(.reset)), #"{"daemon":{"reset":{}}}"#)
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
            .tools,
            .reset,
            .nudge,
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
            .remove(removedPaths: ["a", "b"]),
            .fetch(mode: 0o644),
            .errors(records: [record]),
            .tools(namespaces: [ToolNamespace(namespace: "swift.compiler", toolName: "swiftc",
                                              descriptors: [descriptor])]),
            .debug(text: "⬢ Folder #1"),
        ]
        for response in responses {
            XCTAssertEqual(try roundTrip(Response.daemon(response)), .daemon(response))
        }
    }

    func test_roundTripsEveryErrorResponse() throws {
        let errors: [ErrorResponse] = [
            .pathNotFound(path: "input:/nope"),
            .notAFolder(path: "input:/file"),
            .nodeError(description: "wire missing"),
            .roleNotOffered(role: .runner),
            .malformedRequest(description: "unknown case"),
            .unrecoverable(message: "object store is read-only"),
        ]
        for error in errors {
            XCTAssertEqual(try roundTrip(Response.error(error)), .error(error))
        }
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path SemelProtocol`
Expected: compile failure, `cannot find 'Request' in scope`.

- [ ] **Step 3: Write the daemon messages**

`SemelProtocol/Sources/SemelProtocol/DaemonMessages.swift`:

```swift
// DaemonMessages.swift
// SemelProtocol
//
// The daemon role: a local CLI driving a local build engine. One request per CLI
// operation, structured replies, the client does the formatting. Paths are absolute within
// the named file system and already resolved by the client, so the server never sees `..`.
//
// Every associated value is labelled. Swift's synthesized Codable turns a label into the
// JSON key, so this is what keeps `_0` off the wire; a case that adds a field disturbs
// only its own object.

import Foundation

// MARK: - Shared records

public enum FileSystemName: String, Codable, Equatable {
    case input
    case output
}

public enum EntryKind: String, Codable, Equatable {
    case file
    case folder
}

/// What `ls` prints beside a name today. `missing` and `unreferenced` are the engine's
/// "ghost" entries — referenced but deleted, or the reverse — and hiding them would be a
/// behaviour change.
public enum EntryStatus: String, Codable, Equatable {
    case none
    case missing
    case unreferenced
    case pending
    case error
}

public struct ListEntry: Codable, Equatable {
    public let path:   String
    public let kind:   EntryKind
    public let size:   Int?
    public let mode:   UInt16?
    public let status: EntryStatus

    public init(path: String, kind: EntryKind, size: Int?, mode: UInt16?, status: EntryStatus) {
        self.path   = path
        self.kind   = kind
        self.size   = size
        self.mode   = mode
        self.status = status
    }
}

/// One distinct message a node is carrying, and the ports carrying it. Grouped by message
/// rather than by port because a node that fails usually fails on all of its ports at once
/// with the same reason.
public struct ErrorEntry: Codable, Equatable {
    public let ports:   [String]
    public let message: String

    public init(ports: [String], message: String) {
        self.ports   = ports
        self.message = message
    }
}

public struct ErrorRecord: Codable, Equatable {
    /// What to call the node in a report: a path if it has one, the project file if it is a
    /// builder, the type name otherwise. Decided server-side, where the graph is.
    public let label:   String
    public let entries: [ErrorEntry]

    public init(label: String, entries: [ErrorEntry]) {
        self.label   = label
        self.entries = entries
    }
}

public struct ToolDescriptorRecord: Codable, Equatable {
    public let name:            String
    public let version:         String
    public let platform:        String
    public let architecture:    String
    public let machineSettings: [String: String]

    public init(name: String, version: String, platform: String, architecture: String,
                machineSettings: [String: String]) {
        self.name            = name
        self.version         = version
        self.platform        = platform
        self.architecture    = architecture
        self.machineSettings = machineSettings
    }
}

public struct ToolNamespace: Codable, Equatable {
    public let namespace:   String
    public let toolName:    String
    /// Empty when no such tool is installed; the client prints that as a comment.
    public let descriptors: [ToolDescriptorRecord]

    public init(namespace: String, toolName: String, descriptors: [ToolDescriptorRecord]) {
        self.namespace   = namespace
        self.toolName    = toolName
        self.descriptors = descriptors
    }
}

// MARK: - Requests

public enum DaemonRequest: Codable, Equatable {
    case list(fileSystem: FileSystemName, pattern: String)
    case beginBatch
    case endBatch
    /// The file's bytes travel in the frame body. No hash: hashing lives in SemelNodeKit,
    /// which this package does not link, so the server interns and hashes the bytes itself.
    case pushFile(path: String, mode: UInt16)
    case pushFolder(path: String)
    case remove(pattern: String)
    case fetch(fileSystem: FileSystemName, path: String)
    case errors
    case tools
    case reset
    case nudge
    case debug
    case subscribe
}

// MARK: - Responses

public enum DaemonResponse: Codable, Equatable {
    case ok
    case list(entries: [ListEntry])
    case pushFile(didChange: Bool)
    case remove(removedPaths: [String])
    /// The file's bytes travel in the frame body.
    case fetch(mode: UInt16)
    case errors(records: [ErrorRecord])
    case tools(namespaces: [ToolNamespace])
    case debug(text: String)
}

// MARK: - Events

/// What the engine prints from its background task today, carried to every subscribed
/// connection. B-50's settle diffs become a third case.
public enum DaemonEvent: Codable, Equatable {
    case errors(records: [ErrorRecord])
    case notice(line: String)
}
```

- [ ] **Step 4: Write the role-grouped roots**

`SemelProtocol/Sources/SemelProtocol/Messages.swift`:

```swift
// Messages.swift
// SemelProtocol
//
// The three things that cross the wire, each an enum *of roles*. Which role a message
// belongs to is then a type-level fact: adding a role is a new file rather than an edit to
// every switch, and a server that does not offer a role rejects the whole group with one
// error case. Only `daemon` exists today; `cache` (B-30 role 1) and `runner` (role 2)
// arrive as new cases here and new files beside DaemonMessages.swift.

//
// The roots hand-write their Codable conformance. Their payloads are single values with no
// natural field name, and synthesis would key an unlabelled value as `_0`; labelling it
// would put a meaningless word (`{"daemon":{"request":…}}`) on every message. The
// hand-written form is `{"daemon":{"list":…}}` — the role wrapping the message, nothing
// else — and it is short enough to read in full here.

import Foundation

public enum Request: Equatable {
    case hello(Hello)
    case daemon(DaemonRequest)
}

public enum Response: Equatable {
    case hello(HelloResponse)
    case daemon(DaemonResponse)
    case error(ErrorResponse)
}

public enum Event: Equatable {
    case daemon(DaemonEvent)
}

// MARK: - Codable

extension Request: Codable {

    private enum CodingKeys: String, CodingKey {
        case hello
        case daemon
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key       = try container.singleKey()

        switch key {
        case .hello:  self = .hello(try container.decode(Hello.self, forKey: .hello))
        case .daemon: self = .daemon(try container.decode(DaemonRequest.self, forKey: .daemon))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .hello(let hello):    try container.encode(hello,   forKey: .hello)
        case .daemon(let request): try container.encode(request, forKey: .daemon)
        }
    }
}

extension Response: Codable {

    private enum CodingKeys: String, CodingKey {
        case hello
        case daemon
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key       = try container.singleKey()

        switch key {
        case .hello:  self = .hello(try container.decode(HelloResponse.self, forKey: .hello))
        case .daemon: self = .daemon(try container.decode(DaemonResponse.self, forKey: .daemon))
        case .error:  self = .error(try container.decode(ErrorResponse.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .hello(let hello):     try container.encode(hello,    forKey: .hello)
        case .daemon(let response): try container.encode(response, forKey: .daemon)
        case .error(let error):     try container.encode(error,    forKey: .error)
        }
    }
}

extension Event: Codable {

    private enum CodingKeys: String, CodingKey {
        case daemon
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key       = try container.singleKey()

        switch key {
        case .daemon: self = .daemon(try container.decode(DaemonEvent.self, forKey: .daemon))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .daemon(let event): try container.encode(event, forKey: .daemon)
        }
    }
}

extension KeyedDecodingContainer {

    /// A root message is exactly one role key. Zero keys or two is not a message this build
    /// understands, and the error says which keys were there so a peer mismatch is
    /// diagnosable from the log line.
    func singleKey() throws -> Key {
        guard allKeys.count == 1, let key = allKeys.first else {
            let context = DecodingError.Context(codingPath: codingPath,
                                                debugDescription: "expected exactly one role key, found \(allKeys.map(\.stringValue))")
            throw DecodingError.dataCorrupted(context)
        }
        return key
    }
}

/// Protocol-level failures. Build errors are not among them: a node that fails to compile
/// is data, returned by `errors`, mirroring the engine's distinction between a node failure
/// and an `UnrecoverableError`.
public enum ErrorResponse: Codable, Equatable {
    case pathNotFound(path: String)
    case notAFolder(path: String)
    case nodeError(description: String)
    case roleNotOffered(role: Role)
    case malformedRequest(description: String)
    /// The machine, not the request, is broken. The server answers the in-flight request
    /// with this, then exits; every client sees its connection close.
    case unrecoverable(message: String)
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path SemelProtocol`
Expected: all tests pass. An unknown key at the root (`{"teleport":{}}`) fails in `CodingKeys` before `singleKey()` runs; an unknown key one level down (`{"daemon":{"teleport":{}}}`) fails inside `DaemonRequest`'s synthesized decoder. Both throw `DecodingError`, which is what `test_decodingAnUnknownCaseThrows` asserts.

- [ ] **Step 6: Commit**

```bash
git add SemelProtocol
git commit -m "Define the daemon role's messages and the role-grouped roots

Every associated value is labelled so the JSON carries field names
rather than positional keys; representative messages are asserted as
exact text.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 5: Building frames from messages and reading them back

**Files:**
- Create: `SemelProtocol/Sources/SemelProtocol/Frame+Messages.swift`
- Create: `SemelProtocol/Tests/FrameMessageTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `Frame.request(_:correlationID:body:) throws`, `Frame.response(_:correlationID:body:) throws`, `Frame.event(_:) throws`, `frame.request() throws -> Request`, `frame.response() throws -> Response`, `frame.event() throws -> Event`, `MessageError`. These are what phase 2's `InProcessConnection` and phase 3's `SocketConnection` call.

- [ ] **Step 1: Write the failing tests**

`SemelProtocol/Tests/FrameMessageTests.swift`:

```swift
//
//  FrameMessageTests.swift
//  SemelProtocolTests
//
//  The whole path a message takes: typed value → frame → bytes → frame → typed value.
//  This is what phase 2's in-process connection runs every request through, so that the
//  codec is exercised by every CLI test long before a socket exists.
//

@testable import SemelProtocol
import XCTest

final class FrameMessageTests: XCTestCase {

    func test_requestSurvivesTheWholePath() throws {
        let request = Request.daemon(.pushFile(path: "src/a.c", mode: 0o644))
        let body    = Data("int main() {}".utf8)

        let frame = try Frame.request(request, correlationID: 9, body: body)
        var decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(frame))
        let received = try XCTUnwrap(try decoder.next())

        XCTAssertEqual(received.kind, .request)
        XCTAssertEqual(received.correlationID, 9)
        XCTAssertEqual(try received.request(), request)
        XCTAssertEqual(received.body, body)
    }

    func test_responseSurvivesTheWholePath() throws {
        let response = Response.daemon(.fetch(mode: 0o755))
        let body     = Data([0xCA, 0xFE])

        let frame = try Frame.response(response, correlationID: 9, body: body)
        var decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(frame))
        let received = try XCTUnwrap(try decoder.next())

        XCTAssertEqual(received.kind, .response)
        XCTAssertEqual(try received.response(), response)
        XCTAssertEqual(received.body, body)
    }

    func test_eventUsesCorrelationIDZero() throws {
        let frame = try Frame.event(.daemon(.notice(line: "hi")))

        XCTAssertEqual(frame.kind, .event)
        XCTAssertEqual(frame.correlationID, 0)
        XCTAssertEqual(try frame.event(), .daemon(.notice(line: "hi")))
    }

    func test_bodyDefaultsToEmpty() throws {
        XCTAssertEqual(try Frame.request(.daemon(.reset), correlationID: 1).body, Data())
    }

    func test_readingTheWrongKindIsAnError() throws {
        let frame = try Frame.request(.daemon(.reset), correlationID: 1)

        XCTAssertThrowsError(try frame.response()) { error in
            XCTAssertEqual(error as? MessageError, .wrongKind(expected: .response, actual: .request))
        }
    }

    func test_undecodableJSONIsAnError() {
        let frame = Frame(kind: .request, correlationID: 1, json: Data("not json".utf8))

        XCTAssertThrowsError(try frame.request())
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path SemelProtocol`
Expected: compile failure, `type 'Frame' has no member 'request'`.

- [ ] **Step 3: Write the bridge**

`SemelProtocol/Sources/SemelProtocol/Frame+Messages.swift`:

```swift
// Frame+Messages.swift
// SemelProtocol
//
// Typed messages in and out of frames. A connection — in-process or socket — calls these
// and nothing else; it never touches `MessageCoder` or `Frame.json` directly.

import Foundation

public enum MessageError: Error, Equatable, CustomStringConvertible {
    case wrongKind(expected: FrameKind, actual: FrameKind)

    public var description: String {
        switch self {
        case .wrongKind(let expected, let actual):
            return "expected a \(expected) frame but received a \(actual) frame"
        }
    }
}

extension Frame {

    // MARK: - Building

    public static func request(_ request: Request, correlationID: UInt64, body: Data = Data()) throws -> Frame {
        Frame(kind: .request, correlationID: correlationID, json: try MessageCoder.encode(request), body: body)
    }

    public static func response(_ response: Response, correlationID: UInt64, body: Data = Data()) throws -> Frame {
        Frame(kind: .response, correlationID: correlationID, json: try MessageCoder.encode(response), body: body)
    }

    /// Events answer nothing, so they carry correlation ID zero.
    public static func event(_ event: Event) throws -> Frame {
        Frame(kind: .event, correlationID: 0, json: try MessageCoder.encode(event))
    }

    // MARK: - Reading

    public func request() throws -> Request {
        try requireKind(.request)
        return try MessageCoder.decode(Request.self, from: json)
    }

    public func response() throws -> Response {
        try requireKind(.response)
        return try MessageCoder.decode(Response.self, from: json)
    }

    public func event() throws -> Event {
        try requireKind(.event)
        return try MessageCoder.decode(Event.self, from: json)
    }

    private func requireKind(_ expected: FrameKind) throws {
        guard kind == expected else {
            throw MessageError.wrongKind(expected: expected, actual: kind)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path SemelProtocol`
Expected: all tests pass.

- [ ] **Step 5: Confirm the package has no dependencies and the rest of the tree is untouched**

Run: `grep -rn '^import' SemelProtocol/Sources | grep -v 'import Foundation'`
Expected: no output.

Run: `git status --short`
Expected: only files under `SemelProtocol/` (plus whatever unrelated modifications were already in the tree before this plan started — do not touch or commit those).

- [ ] **Step 6: Commit**

```bash
git add SemelProtocol
git commit -m "Bridge typed messages into frames and back

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 6: Record phase 1 as done

**Files:**
- Modify: `docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md` (the Status line and the "Message types, grouped by role" subsection)
- Modify: `BACKLOG.md` (entry B-30, role 3)

- [ ] **Step 1: Update the spec's status and its one refinement**

Change the status line to:

```
**Status:** phase 1 (SemelProtocol) implemented; phases 2 and 3 not yet started
```

In Section 1, under "Message types, grouped by role", after the sentence ending "…does not disturb its neighbours:", add a paragraph:

```
As built, a payload is a set of *labelled associated values* on the case rather than a
separate struct. Swift's synthesized Codable turns each label into a JSON key, which gives
the same per-case isolation with field names on the wire instead of positional `_0` keys.
Records that several cases share — `ListEntry`, `ErrorRecord`, `ToolNamespace` — are
structs.
```

- [ ] **Step 2: Point B-30 role 3 at the spec**

In `BACKLOG.md`, in entry **B-30**, role 3 currently reads "**Local Build Daemon** — the surviving part of `docs/superpowers/specs/2026-08-15-semel-client-server-design.md`. …". Insert after the first sentence:

```
Designed in `docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md`;
phase 1 of three (the `SemelProtocol` package) is built.
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md BACKLOG.md
git commit -m "Record SemelProtocol as phase 1 of the daemon split

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

## Self-review notes

- **Spec coverage, Section 1:** layout (Task 1), frame (Task 1), codec with incremental decode and pre-allocation limits (Task 2), role-grouped enums (Task 4), daemon table (Task 4: every row is a `DaemonRequest` case with a matching `DaemonResponse`), `Hello` (Task 3), events (Task 4), error responses (Task 4). The "message → frame" bridge the connections need (Section 3) is Task 5.
- **Spec sections 2 to 4** describe phases 2 and 3 and are deliberately not in this plan.
- **Deviations from the spec, both recorded in Task 6:** labelled associated values instead of payload structs; and an explicit `MessageError` for reading a frame of the wrong kind, which the spec did not name.
- **Type consistency:** `DaemonResponse.list(entries:)`, `.errors(records:)`, `.tools(namespaces:)`, `.debug(text:)`, `DaemonEvent.notice(line:)`, `HelloResponse.rejected(reason:)` are used with the same labels in Tasks 3, 4 and 5.
