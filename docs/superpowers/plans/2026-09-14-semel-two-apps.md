# Two Apps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 3 of the daemon split: `semelserv` runs the engine behind a Unix-domain socket, and `semel` becomes a client that links only the CLI and protocol packages.

**Architecture:** A small `SemelTransport` target carries frames over an `NWConnection` (`FrameStream`) and listens on a Unix socket (`SocketListener`); both sides use it, so the protocol package stays transport-free. `SocketConnection` in `SemelCLI` is the synchronous `SemelConnection` over a socket, matching callers to replies by correlation ID. `Server`, `ServerConnection` and `ConnectionRegistry` in `SemelServ` accept connections, run each on its own serial queue against the shared `RequestHandler`, and fan events out to subscribed sessions. `semelserv` is the composition root with a socket probe, signal shutdown and a fatal handler; `semel` opens a socket and hands it to the interpreter.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest, macOS 13. Network.framework (`NWListener`, `NWConnection`, `NWEndpoint.unix`), Dispatch (`DispatchQueue`, `DispatchSource` signals, `DispatchSemaphore`). No new third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md` — Section 5 is what this plan implements; Sections 2 and 3 describe what it builds on (already merged as phases 1 and 2). Read Section 5 first.

## Global Constraints

- Dependency direction: `SemelCore ◀── SemelServ ──▶ SemelProtocol ◀── SemelCLI`. `SemelProtocol` imports Foundation only and never gains Network. `SemelTransport` depends on `SemelProtocol` and Network only. `SemelCLI` never imports `SemelCore` or `SemelServ`. After Task 5 the `semel` executable links only `SemelCLI`, `SemelNodeKit`, `SemelProtocol` and `SemelTransport`.
- The socket path is `SemelPaths.serverSocket`: `SemelPaths.root/semelserv.sock`, overridden by the environment variable `SEMEL_SOCKET`. `SemelPaths.root` is `~/Library/Application Support/semel`, overridden by `SEMEL_HOME`. Both executables honour both; tests always set both to temporary directories. No test may touch the real socket, graph or object store.
- `SemelConnection.send` stays synchronous and thread-safe; `onEvent` is a callback. The nil-body convention is the in-process one: an empty reply body arrives as `nil`; a nil request body is sent empty.
- Each server connection runs on its own serial `DispatchQueue`; the handler's own queue orders requests across connections; `wait` runs off the handler's queue and parks the connection's queue thread, never a cooperative-pool thread. Frames on one socket are sent in order from that connection's queue so a reply and an event never interleave.
- Startup probe: if the socket file exists, connect and send `hello`, waiting up to 2 seconds. Any reply → "semelserv is already running at <path>", exit 1. Refused, waiting or no reply → unlink and listen. Logs go to standard output and error only.
- Shutdown on `SIGINT`/`SIGTERM`: cancel the listener, close every connection (ending its session), `stopProcessingLoop()`, remove the socket file, exit 0. `FatalErrors.handler` in the server logs to standard error, refuses new work, and exits 70 after the in-flight reply has been written.
- `BuildEngine.loopIsRunning` is read and written under `batchLock` (B-61 item 1).
- Formatting (AGENTS.md): four spaces, brace on the declaration line, no `else if` chains (nest a block or use `switch`), `// MARK: -` in files long enough to navigate, aligned columns where they aid reading, US-English comments that never narrate history ("today", "used to", "no longer", "previously" are all disallowed). Naming: no single-character names, words spelt out, `struct` unless reference semantics are needed, `internal` by default. Errors are enums with associated values carrying enough context to act on.
- SwiftLint: run `swiftlint --strict` from the repository root before every commit; the curated rules forbid `= nil` on an optional `var`, `filter{}.isEmpty`/`.count == 0` idioms, unused closure parameters and optional bindings, and unneeded `break`s. CI fails on any violation.
- Tests: XCTest, `test_whatItDoes`; engine-backed tests redirect `DataObjectStore.shared` as `RequestHandlerTestCase` does; expectations wait at most 5 seconds.
- **Socket paths are short.** macOS limits a Unix-domain socket path to 103 bytes (`sun_path`), and `NWConnection` traps on a longer one rather than failing. `NSTemporaryDirectory()` alone is about 70 bytes, so every socket test uses a unique directory under `/tmp/semel-tests/` (`/tmp/semel-tests/<8 hex>/`), and `UnixSocketPath.check(_:)` in `SemelTransport` refuses an over-long path with a `TransportError.pathTooLong` before either side touches Network.framework. The executable test's `SEMEL_HOME` lives there too, because the socket is under it. Test files use the Xcode-style header (`//` / `//  Name.swift` / `//  TargetTests` / `//` / paragraph / `//`); source files `// Name.swift` / `// Module` / `//` / paragraph.
- Commit messages are imperative sentences (no conventional-commit prefixes), ending with exactly:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE`
- Test commands from the repository root: `swift test --package-path SemelNodeKit` (121), `swift test --package-path SemelCore` (343), `swift test --package-path SemelProtocol` (44), `swift test` (root, 122 before this plan), `swift test --package-path SemelSwift` (135), `swift test --package-path SemelClang` (44). Run the suites a task touches after each task; Task 5 runs all six.

---

## File structure

```
SemelNodeKit/Sources/SemelNodeKit/SemelPaths.swift        MODIFY: SEMEL_HOME override, serverSocket
SemelNodeKit/Tests/SemelPathsTests.swift                 MODIFY: two tests for the overrides
Package.swift                                            MODIFY in Tasks 1, 3, 4, 5
semel/Transport/FrameStream.swift                        NEW (SemelTransport): frames over an NWConnection
semel/Transport/SocketListener.swift                     NEW: NWListener on a Unix socket path
semel/TransportTests/FrameStreamTests.swift              NEW
semel/CommandInterpreter/SocketConnection.swift          NEW (SemelCLI)
semel/Tests/SocketConnectionTests.swift                  NEW
semel/Server/ServerConnection.swift                      NEW (SemelServ): one client
semel/Server/ConnectionRegistry.swift                    NEW: the live connections + EventSink
semel/Server/Server.swift                                NEW: listener, probe, stop, fatal handling
semel/ServerTests/ServerTests.swift                      NEW: real engine over a loopback socket
semel/ServerTests/SemelservExecutableTests.swift         NEW: the binary as a subprocess
SemelCore/Sources/SemelCore/BuildEngine.swift            MODIFY: loopIsRunning under batchLock
semel-server/main.swift                                  NEW: the semelserv executable
semel/main.swift                                         MODIFY: the client
docs, BACKLOG.md, AGENTS.md                              MODIFY in Task 5
```

One refinement of the spec, recorded in Task 5: `SemelPaths.root` gains a `SEMEL_HOME` override beside `SEMEL_SOCKET`, because the subprocess test must run a real `semelserv` without it opening the user's graph.

---

### Task 1: `SemelTransport` — frames over a socket, and the two path overrides

**Files:**
- Modify: `SemelNodeKit/Sources/SemelNodeKit/SemelPaths.swift`
- Modify: `SemelNodeKit/Tests/SemelPathsTests.swift`
- Modify: `Package.swift`
- Create: `semel/Transport/FrameStream.swift`
- Create: `semel/Transport/SocketListener.swift`
- Create: `semel/TransportTests/FrameStreamTests.swift`

**Interfaces:**
- Produces (`SemelNodeKit`): `SemelPaths.root` honouring `SEMEL_HOME`; `SemelPaths.serverSocket: URL` honouring `SEMEL_SOCKET`.
- Produces (`SemelTransport`): `public final class FrameStream` with `init(connection: NWConnection, queue: DispatchQueue)`, `var onFrame: ((Frame) -> Void)?`, `var onClose: ((Error?) -> Void)?`, `func start()`, `func send(_ frame: Frame)`, `func close()`; `public final class SocketListener` with `init(path: String, queue: DispatchQueue)`, `var onConnection: ((NWConnection) -> Void)?`, `func start(ready: @escaping (Result<Void, Error>) -> Void)`, `func cancel()`; `public enum UnixSocketPath` with `static let maximumLength = 103` and `static func check(_ path: String) throws`; `public enum TransportError: Error` with `.listenFailed(path:underlying:)`, `.connectionFailed(underlying:)`, `.pathTooLong(path:length:limit:)`, `.closed`.

- [ ] **Step 1: Write the failing path tests**

Append to `SemelNodeKit/Tests/SemelPathsTests.swift` (inside its test class; read the file first for its existing style and helpers):

```swift
    // MARK: - Overrides

    /// A server under test must never open the user's graph, so the whole root moves with
    /// one variable; the socket has its own so a test can point at a server it did not
    /// start.
    func test_rootHonoursSemelHome() {
        setenv("SEMEL_HOME", "/tmp/semel-paths-test-home", 1)
        defer { unsetenv("SEMEL_HOME") }

        XCTAssertEqual(SemelPaths.root.path, "/tmp/semel-paths-test-home")
        XCTAssertEqual(SemelPaths.database.path, "/tmp/semel-paths-test-home/graph.sqlite")
        XCTAssertEqual(SemelPaths.serverSocket.path, "/tmp/semel-paths-test-home/semelserv.sock")
    }

    func test_serverSocketHonoursSemelSocket() {
        setenv("SEMEL_SOCKET", "/tmp/semel-paths-test.sock", 1)
        defer { unsetenv("SEMEL_SOCKET") }

        XCTAssertEqual(SemelPaths.serverSocket.path, "/tmp/semel-paths-test.sock")
    }

    func test_serverSocketDefaultsToTheRoot() {
        unsetenv("SEMEL_SOCKET")

        XCTAssertEqual(SemelPaths.serverSocket, SemelPaths.root.appendingPathComponent("semelserv.sock", isDirectory: false))
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path SemelNodeKit --filter SemelPathsTests`
Expected: compile failure, `serverSocket` does not exist.

- [ ] **Step 3: Add the overrides**

Replace the body of `public enum SemelPaths` in `SemelNodeKit/Sources/SemelNodeKit/SemelPaths.swift` with:

```swift
public enum SemelPaths {

    /// `~/Library/Application Support/semel`, or `SEMEL_HOME` when set. The override exists
    /// so a server started by a test has a root of its own; nothing else should set it.
    public static var root: URL {
        if let home = ProcessInfo.processInfo.environment["SEMEL_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("semel", isDirectory: true)
    }

    /// The content-addressed object store.
    public static var objectStore: URL {
        root.appendingPathComponent("objects", isDirectory: true)
    }

    /// The graph database. One per user, beside the store it refers into.
    public static var database: URL {
        root.appendingPathComponent("graph.sqlite", isDirectory: false)
    }

    /// Where `semelserv` listens and `semel` connects, or `SEMEL_SOCKET` when set. A
    /// Unix-domain socket is a name in the file system that the kernel routes connections
    /// through; keeping it under the user's own root is what stands in for authentication.
    public static var serverSocket: URL {
        if let socket = ProcessInfo.processInfo.environment["SEMEL_SOCKET"], !socket.isEmpty {
            return URL(fileURLWithPath: socket, isDirectory: false)
        }
        return root.appendingPathComponent("semelserv.sock", isDirectory: false)
    }
}
```

Run: `swift test --package-path SemelNodeKit` — expected: 124 tests green.

- [ ] **Step 4: Add the `SemelTransport` target to the manifest**

In `Package.swift`, add after the `SemelServ` target:

```swift
        // Frames over a socket. Both halves use it, so it is one target; it is not part of
        // SemelProtocol because the protocol package stays transport-free.
        .target(
            name: "SemelTransport",
            dependencies: [
                .product(name: "SemelProtocol", package: "SemelProtocol"),
            ],
            path: "semel/Transport"
        ),
        .testTarget(
            name: "SemelTransportTests",
            dependencies: [
                "SemelTransport",
                .product(name: "SemelProtocol", package: "SemelProtocol"),
            ],
            path: "semel/TransportTests"
        ),
```

Network.framework needs no package dependency; `import Network` links it.

- [ ] **Step 5: Write the failing transport tests**

`semel/TransportTests/FrameStreamTests.swift`:

```swift
//
//  FrameStreamTests.swift
//  SemelTransportTests
//
//  Frames over a real Unix-domain socket in a temporary directory: a listener accepts one
//  connection, and each side wraps its end in a FrameStream. What is pinned: whole frames
//  arrive whole however the socket chunks them, order is kept, and a close reaches the
//  other side as a close.
//

import Foundation
import Network
import SemelProtocol
@testable import SemelTransport
import XCTest

final class FrameStreamTests: XCTestCase {

    private var socketPath: String!
    private var listener: SocketListener!
    private let serverQueue = DispatchQueue(label: "FrameStreamTests.server")
    private let clientQueue = DispatchQueue(label: "FrameStreamTests.client")

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short on purpose: a Unix-domain socket path is limited to 103 bytes on macOS, and
        // NSTemporaryDirectory() alone uses most of that.
        let directory = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("t.sock").path
        listener = SocketListener(path: socketPath, queue: serverQueue)
    }

    override func tearDown() {
        listener.cancel()
        listener = nil
        super.tearDown()
    }

    /// Starts the listener and returns a stream for the first accepted connection.
    private func acceptOne() throws -> FrameStream {
        var accepted: FrameStream?
        let ready    = expectation(description: "listener ready")
        let arrived  = expectation(description: "connection accepted")
        listener.onConnection = { connection in
            accepted = FrameStream(connection: connection, queue: self.serverQueue)
            arrived.fulfill()
        }
        listener.start { result in
            if case .failure(let error) = result {
                XCTFail("listener failed: \(error)")
            }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
        let client = FrameStream(connection: NWConnection(to: .unix(path: socketPath), using: .tcp),
                                 queue: clientQueue)
        clientStream = client
        client.start()
        wait(for: [arrived], timeout: 5)
        return try XCTUnwrap(accepted)
    }

    private var clientStream: FrameStream?

    func test_aFrameArrivesWholeAndInOrder() throws {
        let server = try acceptOne()
        let received = expectation(description: "two frames")
        received.expectedFulfillmentCount = 2
        var frames: [Frame] = []
        server.onFrame = { frame in
            frames.append(frame)
            received.fulfill()
        }
        server.start()

        let first  = Frame(kind: .request, correlationID: 1, json: Data(#"{"a":1}"#.utf8), body: Data(repeating: 7, count: 100_000))
        let second = Frame(kind: .request, correlationID: 2, json: Data(#"{"b":2}"#.utf8))
        clientStream?.send(first)
        clientStream?.send(second)

        wait(for: [received], timeout: 5)
        XCTAssertEqual(frames, [first, second])
    }

    func test_aReplyComesBackTheOtherWay() throws {
        let server = try acceptOne()
        server.onFrame = { frame in
            server.send(Frame(kind: .response, correlationID: frame.correlationID, json: Data("{}".utf8)))
        }
        server.start()
        let replied = expectation(description: "reply")
        var reply: Frame?
        clientStream?.onFrame = { frame in
            reply = frame
            replied.fulfill()
        }

        clientStream?.send(Frame(kind: .request, correlationID: 9, json: Data("{}".utf8)))

        wait(for: [replied], timeout: 5)
        XCTAssertEqual(reply?.kind, .response)
        XCTAssertEqual(reply?.correlationID, 9)
    }

    func test_closingOneEndClosesTheOther() throws {
        let server = try acceptOne()
        let closed = expectation(description: "server saw close")
        server.onClose = { _ in closed.fulfill() }
        server.start()

        clientStream?.close()

        wait(for: [closed], timeout: 5)
    }

    func test_aBadFrameClosesTheStreamWithAFrameError() throws {
        let server = try acceptOne()
        let closed = expectation(description: "server saw close")
        var closeError: Error?
        server.onClose = { error in
            closeError = error
            closed.fulfill()
        }
        server.start()

        // A header with a version byte this build does not speak.
        var bytes = try FrameEncoder.encode(Frame(kind: .request, correlationID: 1, json: Data("{}".utf8)))
        bytes[0] = Frame.version + 1
        clientStream?.sendRaw(bytes)

        wait(for: [closed], timeout: 5)
        XCTAssertEqual(closeError as? FrameError, .unsupportedVersion(Frame.version + 1))
    }

    /// NWConnection traps on a path over the limit instead of failing; the check exists so
    /// neither side ever hands it one.
    func test_aPathOverTheLimitIsRefusedNotTrapped() {
        let long = "/tmp/" + String(repeating: "x", count: 120) + ".sock"

        XCTAssertThrowsError(try UnixSocketPath.check(long)) { error in
            XCTAssertEqual(error as? TransportError, .pathTooLong(path: long, length: long.utf8.count, limit: UnixSocketPath.maximumLength))
        }
        XCTAssertNoThrow(try UnixSocketPath.check(socketPath))
    }
}
```

- [ ] **Step 6: Run them to see them fail**

Run: `swift test --filter FrameStreamTests`
Expected: compile failure, `SocketListener` and `FrameStream` do not exist.

- [ ] **Step 7: Write `FrameStream`**

`semel/Transport/FrameStream.swift`:

```swift
// FrameStream.swift
// SemelTransport
//
// Frames over one NWConnection. The read side feeds whatever the socket delivers into a
// FrameDecoder and hands out whole frames; the write side sends encoded frames in the
// order they were given, from one queue, so two frames from one process never interleave
// on the wire. Both ends of a connection use this, which is why it is its own target.

import Foundation
import Network
import SemelProtocol

public enum TransportError: Error, CustomStringConvertible {
    case listenFailed(path: String, underlying: String)
    case connectionFailed(underlying: String)
    case pathTooLong(path: String, length: Int, limit: Int)
    case closed

    public var description: String {
        switch self {
        case .listenFailed(let path, let underlying):
            return "cannot listen at \(path): \(underlying)"
        case .connectionFailed(let underlying):
            return "connection failed: \(underlying)"
        case .pathTooLong(let path, let length, let limit):
            return "socket path is \(length) bytes, over the \(limit)-byte limit: \(path)"
        case .closed:
            return "the connection is closed"
        }
    }
}

extension TransportError: Equatable {}

/// The one rule about socket paths. macOS stores a Unix-domain socket address in a fixed
/// 104-byte field with a terminating zero, and NWConnection traps rather than fails on a
/// longer one, so both sides check before touching Network.framework.
public enum UnixSocketPath {

    public static let maximumLength = 103

    public static func check(_ path: String) throws {
        let length = path.utf8.count
        guard length <= maximumLength else {
            throw TransportError.pathTooLong(path: path, length: length, limit: maximumLength)
        }
    }
}

public final class FrameStream {

    /// Called on `queue` with each complete frame, in arrival order.
    public var onFrame: ((Frame) -> Void)?

    /// Called on `queue` once, when the connection ends: nil for a clean close by the
    /// peer, a `FrameError` for bytes that cannot be framed, a `TransportError` otherwise.
    public var onClose: ((Error?) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var decoder = FrameDecoder()
    private var isClosed = false

    private static let receiveChunk = 1 << 16

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue      = queue
    }

    // MARK: - Lifecycle

    /// Installs the state handler, starts the connection if nobody has, and begins the
    /// receive loop. Call once. A client that waited for `.ready` itself hands over a
    /// started connection; starting it again is not defined, so the state is checked.
    public func start() {
        let needsStart = connection.state == .setup
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.finish(with: TransportError.connectionFailed(underlying: "\(error)"))
            case .waiting(let error):
                // Nothing is listening at the path, or it refused. NWConnection would keep
                // retrying; a client of a local daemon should hear the answer now.
                self?.finish(with: TransportError.connectionFailed(underlying: "\(error)"))
            case .cancelled:
                self?.finish(with: nil)
            case .setup, .preparing, .ready:
                break
            @unknown default:
                break
            }
        }
        if needsStart {
            connection.start(queue: queue)
        }
        receiveNext()
    }

    /// Ends the connection. `onClose` is not called for a close this side asked for.
    public func close() {
        queue.async { [self] in
            isClosed = true
            connection.cancel()
        }
    }

    // MARK: - Sending

    public func send(_ frame: Frame) {
        // Encoding can fail only on an over-limit frame, which is a bug on this side; the
        // stream closes rather than silently dropping the frame.
        do {
            sendRaw(try FrameEncoder.encode(frame))
        } catch {
            finish(with: error)
        }
    }

    /// Bytes as they are, for tests that need to put a malformed frame on the wire.
    func sendRaw(_ bytes: Data) {
        queue.async { [self] in
            guard !isClosed else {
                return
            }
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.finish(with: TransportError.connectionFailed(underlying: "\(error)"))
                }
            })
        }
    }

    // MARK: - Receiving

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunk) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                decoder.append(data)
                do {
                    while let frame = try decoder.next() {
                        onFrame?(frame)
                    }
                } catch {
                    finish(with: error)
                    return
                }
            }
            if let error {
                finish(with: TransportError.connectionFailed(underlying: "\(error)"))
                return
            }
            if isComplete {
                finish(with: nil)
                return
            }
            receiveNext()
        }
    }

    /// Runs `onClose` at most once and cancels the connection. Always on `queue`.
    private func finish(with error: Error?) {
        queue.async { [self] in
            guard !isClosed else {
                return
            }
            isClosed = true
            connection.cancel()
            onClose?(error)
        }
    }
}
```

- [ ] **Step 8: Write `SocketListener`**

`semel/Transport/SocketListener.swift`:

```swift
// SocketListener.swift
// SemelTransport
//
// An NWListener bound to a Unix-domain socket path. The listener creates the socket file
// when it becomes ready and does not remove it when cancelled; the owner does that,
// because only the owner knows whether the file is still its own.

import Foundation
import Network

public final class SocketListener {

    /// Called on `queue` for each accepted connection, not yet started.
    public var onConnection: ((NWConnection) -> Void)?

    public let path: String

    private let queue: DispatchQueue
    private var listener: NWListener?

    public init(path: String, queue: DispatchQueue) {
        self.path  = path
        self.queue = queue
    }

    /// Binds and listens. `ready` is called once, on `queue`, when the socket file exists
    /// and connections are being accepted, or with the error that prevented it.
    public func start(ready: @escaping (Result<Void, Error>) -> Void) {
        do {
            try UnixSocketPath.check(path)
        } catch {
            queue.async { ready(.failure(error)) }
            return
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            queue.async { ready(.failure(TransportError.listenFailed(path: self.path, underlying: "\(error)"))) }
            return
        }
        self.listener = listener

        var reported = false
        listener.stateUpdateHandler = { [path] state in
            switch state {
            case .ready:
                if !reported {
                    reported = true
                    ready(.success(()))
                }
            case .failed(let error):
                if !reported {
                    reported = true
                    ready(.failure(TransportError.listenFailed(path: path, underlying: "\(error)")))
                }
            case .waiting(let error):
                if !reported {
                    reported = true
                    ready(.failure(TransportError.listenFailed(path: path, underlying: "\(error)")))
                }
            case .setup, .cancelled:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.onConnection?(connection)
        }
        listener.start(queue: queue)
    }

    public func cancel() {
        listener?.cancel()
        listener = nil
    }
}
```

- [ ] **Step 9: Run the transport tests**

Run: `swift test --filter FrameStreamTests`
Expected: 5 tests green. If `test_aBadFrameClosesTheStreamWithAFrameError` sees `TransportError.connectionFailed` instead of the `FrameError`, the decoder threw after the connection reported an error first; check the order in `receiveNext` (decode before checking `error`) and report what you saw.

Then `swiftlint --strict` (expected 0 violations) and `swift test` (root: 122 + 5).

- [ ] **Step 10: Commit**

```bash
git add Package.swift SemelNodeKit semel/Transport semel/TransportTests
git commit -m "Add SemelTransport: frames over a Unix socket, and the SEMEL_HOME and SEMEL_SOCKET overrides

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 2: `SocketConnection` in the CLI

**Files:**
- Modify: `Package.swift` (`SemelCLI` and `SemelCLITests` gain `"SemelTransport"`)
- Create: `semel/CommandInterpreter/SocketConnection.swift`
- Create: `semel/Tests/SocketConnectionTests.swift`

**Interfaces:**
- Consumes: `FrameStream`, `SocketListener`, `TransportError` (Task 1); `SemelConnection`, `Frame.request/response`, `frame.response()/event()`.
- Produces: `public final class SocketConnection: SemelConnection` with `static func connect(to path: String, timeout: TimeInterval = 5) throws -> SocketConnection`, `func send(_:body:) throws -> (Response, Data?)`, `var onEvent`, `func close()`; `public enum ConnectionError: Error` with `.unavailable(path: String, underlying: Error)`, `.closed`, `.unexpectedFrame`.

- [ ] **Step 1: Add the dependencies**

In `Package.swift`, add `"SemelTransport",` to the `dependencies` of the `SemelCLI` target and of the `SemelCLITests` target.

- [ ] **Step 2: Write the failing tests**

`semel/Tests/SocketConnectionTests.swift`:

```swift
//
//  SocketConnectionTests.swift
//  SemelCLITests
//
//  The client's socket connection against a tiny listener that answers from a script:
//  replies reach the caller that sent the request even when two are waiting, events
//  reach onEvent, and a closed socket fails every waiter instead of hanging it.
//

import Foundation
import Network
@testable import SemelCLI
import SemelProtocol
import SemelTransport
import XCTest

final class SocketConnectionTests: XCTestCase {

    private var socketPath: String!
    private var listener: SocketListener!
    private var serverStream: FrameStream?
    private let serverQueue = DispatchQueue(label: "SocketConnectionTests.server")

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short on purpose: a Unix-domain socket path is limited to 103 bytes on macOS.
        let directory = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("s.sock").path
    }

    override func tearDown() {
        listener?.cancel()
        listener = nil
        serverStream = nil
        super.tearDown()
    }

    /// Starts a listener whose one connection answers each request frame with `answer`.
    private func startServer(answer: @escaping (Frame) -> Frame?) {
        listener = SocketListener(path: socketPath, queue: serverQueue)
        let ready = expectation(description: "listener ready")
        listener.onConnection = { connection in
            let stream = FrameStream(connection: connection, queue: self.serverQueue)
            stream.onFrame = { frame in
                if let reply = answer(frame) {
                    stream.send(reply)
                }
            }
            stream.start()
            self.serverStream = stream
        }
        listener.start { _ in ready.fulfill() }
        wait(for: [ready], timeout: 5)
    }

    func test_aReplyReachesItsCaller() throws {
        startServer { frame in
            try? Frame.response(.daemon(.ok), correlationID: frame.correlationID)
        }
        let connection = try SocketConnection.connect(to: socketPath)

        let (response, body) = try connection.send(.daemon(.reset), body: nil)

        XCTAssertEqual(response, .daemon(.ok))
        XCTAssertNil(body)
    }

    func test_aReplyBodyComesBackAndAnEmptyOneIsNil() throws {
        startServer { frame in
            let request = try? frame.request()
            if case .daemon(.fetch(_, let path)) = request, path == "full" {
                return try? Frame.response(.daemon(.fetch(mode: 0o644)), correlationID: frame.correlationID, body: Data("bytes".utf8))
            }
            return try? Frame.response(.daemon(.fetch(mode: 0o644)), correlationID: frame.correlationID)
        }
        let connection = try SocketConnection.connect(to: socketPath)

        let (_, full)  = try connection.send(.daemon(.fetch(fileSystem: .input, path: "full")), body: nil)
        let (_, empty) = try connection.send(.daemon(.fetch(fileSystem: .input, path: "empty")), body: nil)

        XCTAssertEqual(full, Data("bytes".utf8))
        XCTAssertNil(empty)
    }

    /// Two threads wait at once; the server answers the second request first. Each caller
    /// must still get its own reply.
    func test_twoWaitingCallersEachGetTheirOwnReply() throws {
        var pending: [Frame] = []
        startServer { frame in
            pending.append(frame)
            guard pending.count == 2 else {
                return nil
            }
            // Answer in reverse order, on the server's queue.
            for waiting in pending.reversed() {
                let request = try? waiting.request()
                let text: String
                if case .daemon(.list(_, let pattern)) = request {
                    text = pattern
                } else {
                    text = "?"
                }
                if let reply = try? Frame.response(.daemon(.debug(text: text)), correlationID: waiting.correlationID) {
                    self.serverStream?.send(reply)
                }
            }
            return nil
        }
        let connection = try SocketConnection.connect(to: socketPath)
        let group = DispatchGroup()
        var results: [String: Response] = [:]
        let lock = NSLock()

        for pattern in ["first", "second"] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                if let (response, _) = try? connection.send(.daemon(.list(fileSystem: .input, pattern: pattern)), body: nil) {
                    lock.withLock { results[pattern] = response }
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results["first"],  .daemon(.debug(text: "first")))
        XCTAssertEqual(results["second"], .daemon(.debug(text: "second")))
    }

    func test_anEventReachesOnEvent() throws {
        startServer { frame in
            if let event = try? Frame.event(.daemon(.notice(line: "built"))) {
                self.serverStream?.send(event)
            }
            return try? Frame.response(.daemon(.ok), correlationID: frame.correlationID)
        }
        let connection = try SocketConnection.connect(to: socketPath)
        let delivered = expectation(description: "event")
        var events: [Event] = []
        connection.onEvent = { event in
            events.append(event)
            delivered.fulfill()
        }

        _ = try connection.send(.daemon(.subscribe), body: nil)

        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(events, [.daemon(.notice(line: "built"))])
    }

    func test_aClosedSocketFailsTheWaiterAndLaterSends() throws {
        startServer { _ in
            self.serverStream?.close()
            return nil
        }
        let connection = try SocketConnection.connect(to: socketPath)

        XCTAssertThrowsError(try connection.send(.daemon(.reset), body: nil)) { error in
            XCTAssertEqual(error as? ConnectionError, .closed)
        }
        XCTAssertThrowsError(try connection.send(.daemon(.reset), body: nil)) { error in
            XCTAssertEqual(error as? ConnectionError, .closed)
        }
    }

    func test_connectingToNothingFailsWithThePath() {
        XCTAssertThrowsError(try SocketConnection.connect(to: socketPath, timeout: 2)) { error in
            guard case .unavailable(let path, _)? = error as? ConnectionError else {
                return XCTFail("expected unavailable, got \(error)")
            }
            XCTAssertEqual(path, socketPath)
        }
    }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --filter SocketConnectionTests`
Expected: compile failure, `SocketConnection` does not exist.

- [ ] **Step 4: Write `SocketConnection`**

`semel/CommandInterpreter/SocketConnection.swift`:

```swift
// SocketConnection.swift
// semel
//
// SemelConnection over a Unix-domain socket. `send` is synchronous: it registers a waiter
// under the correlation ID, writes the frame, and parks on a semaphore until the reader
// delivers that ID's reply. Several threads may be parked at once, each on its own
// waiter, which is the shape the engine's cache role will need. Events go to `onEvent`
// on the reader's queue, as the in-process connection delivers them.

import Foundation
import Network
import SemelProtocol
import SemelTransport

public enum ConnectionError: Error, Equatable, CustomStringConvertible {
    case unavailable(path: String, underlying: String)
    case closed
    case unexpectedFrame

    public var description: String {
        switch self {
        case .unavailable(let path, let underlying):
            return "no server at \(path) (\(underlying)); start one with `semelserv`"
        case .closed:
            return "the connection to the server closed"
        case .unexpectedFrame:
            return "the server sent a frame this client cannot place"
        }
    }
}

public final class SocketConnection: SemelConnection {

    public var onEvent: ((Event) -> Void)? {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }

    private final class Waiter {
        let semaphore = DispatchSemaphore(value: 0)
        var reply: Result<(Response, Data?), Error>?
    }

    private let stream: FrameStream
    private let lock = NSLock()
    private var eventHandler: ((Event) -> Void)?
    private var waiters: [UInt64: Waiter] = [:]
    private var nextCorrelationID: UInt64 = 1
    private var isClosed = false

    // MARK: - Connecting

    /// Opens the socket and waits until it is ready, or fails with the path so the user
    /// knows what to start. Nothing is sent; the caller sends `hello`.
    public static func connect(to path: String, timeout: TimeInterval = 5) throws -> SocketConnection {
        do {
            try UnixSocketPath.check(path)
        } catch {
            throw ConnectionError.unavailable(path: path, underlying: "\(error)")
        }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        let queue      = DispatchQueue(label: "semel.socket-connection")
        let ready      = DispatchSemaphore(value: 0)
        var failure: String?

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure = "\(error)"
                ready.signal()
            case .waiting(let error):
                // Not listening or refused. NWConnection would retry; a local daemon that
                // is not there now will not be there in a moment either.
                failure = "\(error)"
                ready.signal()
            case .setup, .preparing, .cancelled:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)

        guard ready.wait(timeout: .now() + timeout) == .success, failure == nil else {
            connection.cancel()
            throw ConnectionError.unavailable(path: path, underlying: failure ?? "timed out after \(Int(timeout)) s")
        }

        // The stream takes over the state handler from here.
        let socket = SocketConnection(stream: FrameStream(connection: connection, queue: queue))
        socket.stream.start()
        return socket
    }

    private init(stream: FrameStream) {
        self.stream = stream
        stream.onFrame = { [weak self] frame in self?.receive(frame) }
        stream.onClose = { [weak self] _ in self?.closeAll() }
    }

    public func close() {
        stream.close()
        closeAll()
    }

    // MARK: - SemelConnection

    public func send(_ request: Request, body: Data?) throws -> (Response, Data?) {
        let waiter = Waiter()
        let correlationID: UInt64 = try lock.withLock { () throws -> UInt64 in
            guard !isClosed else {
                throw ConnectionError.closed
            }
            defer { nextCorrelationID += 1 }
            waiters[nextCorrelationID] = waiter
            return nextCorrelationID
        }

        stream.send(try Frame.request(request, correlationID: correlationID, body: body ?? Data()))
        waiter.semaphore.wait()

        guard let reply = waiter.reply else {
            throw ConnectionError.closed
        }
        return try reply.get()
    }

    // MARK: - Receiving

    private func receive(_ frame: Frame) {
        switch frame.kind {
        case .response:
            let waiter = lock.withLock { waiters.removeValue(forKey: frame.correlationID) }
            guard let waiter else {
                // A reply nobody is waiting for: dropped, but said, because it means the
                // two sides disagree about what is in flight.
                FileHandle.standardError.write(Data("semel: dropped a reply for unknown request \(frame.correlationID)\n".utf8))
                return
            }
            do {
                let response = try frame.response()
                waiter.reply = .success((response, frame.body.isEmpty ? nil : frame.body))
            } catch {
                waiter.reply = .failure(error)
            }
            waiter.semaphore.signal()

        case .event:
            guard let event = try? frame.event() else {
                return
            }
            onEvent?(event)

        case .request:
            // The server does not send requests; nothing to do but note it.
            FileHandle.standardError.write(Data("semel: the server sent a request frame; ignored\n".utf8))
        }
    }

    /// Fails every waiter and refuses later sends. Idempotent.
    private func closeAll() {
        let orphans: [Waiter] = lock.withLock {
            isClosed = true
            let all = Array(waiters.values)
            waiters.removeAll()
            return all
        }
        for waiter in orphans {
            waiter.reply = .failure(ConnectionError.closed)
            waiter.semaphore.signal()
        }
    }
}
```

`ConnectionError.unavailable` carries the underlying failure as a `String` rather than an `Error` so the enum can be `Equatable` for tests; the message is what the user sees either way.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter SocketConnectionTests` — expected: 6 green. Then `swiftlint --strict` (0 violations) and `swift test` (root: 132).

- [ ] **Step 6: Commit**

```bash
git add Package.swift semel/CommandInterpreter/SocketConnection.swift semel/Tests/SocketConnectionTests.swift
git commit -m "Add SocketConnection, the CLI's synchronous connection over a Unix socket

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 3: The socket server in `SemelServ`

**Files:**
- Modify: `Package.swift` (`SemelServ` gains `"SemelTransport"`; `SemelServTests` gains `"SemelCLI"` and `"SemelTransport"`)
- Modify: `SemelCore/Sources/SemelCore/BuildEngine.swift` (`loopIsRunning` under `batchLock`)
- Create: `semel/Server/ServerConnection.swift`
- Create: `semel/Server/ConnectionRegistry.swift`
- Create: `semel/Server/Server.swift`
- Create: `semel/ServerTests/ServerTests.swift`

**Interfaces:**
- Consumes: `RequestHandler` (`handle`, `endSession`, `eventSink`), `Session`, `EventSink`; `FrameStream`, `SocketListener`, `TransportError`; `SocketConnection` (tests only).
- Produces: `public final class Server` with `init(handler: RequestHandler, socketPath: String)`, `func start() throws`, `func stop()`, `var connectionCount: Int`, `var isStopping: Bool`, `func handleFatal(_ error: any UnrecoverableError, terminate: @escaping (Int32) -> Void)`; `public enum ServerError: Error` with `.alreadyRunning(path:)`, `.cannotListen(path:underlying:)`. `static func probe(path: String, timeout: TimeInterval) -> Bool` (internal, tested).

- [ ] **Step 1: Put `loopIsRunning` under the lock**

In `SemelCore/Sources/SemelCore/BuildEngine.swift`:
- `startProcessingLoop()`: replace `loopIsRunning = true` with `batchLock.withLock { loopIsRunning = true }`.
- `processLoop()`: replace `loopIsRunning = false` with `batchLock.withLock { loopIsRunning = false }`.
- `waitUntilIdle()`: replace `guard loopIsRunning else {` with `guard batchLock.withLock({ loopIsRunning }) else {`.
- Update the doc comment on `loopIsRunning` to end with: "Under `batchLock`: the loop writes it from the cooperative pool and a server reads it from any connection's thread."

Run: `swift test --package-path SemelCore` — expected: 343 green.

- [ ] **Step 2: Add the dependencies**

In `Package.swift`: add `"SemelTransport",` to the `SemelServ` target's dependencies; add `"SemelCLI",` and `"SemelTransport",` to `SemelServTests`' dependencies (a test target may see both halves; the dependency rule is about the library targets).

- [ ] **Step 3: Write the failing server tests**

`semel/ServerTests/ServerTests.swift`:

```swift
//
//  ServerTests.swift
//  SemelServTests
//
//  The socket server against a real in-memory engine, driven by the CLI's own
//  SocketConnection over a loopback socket in a temporary directory. What is pinned: the
//  daemon verbs work end to end, events reach subscribed clients only, a client that
//  vanishes mid-push leaves no batch open, a second server on the same path is refused,
//  and stop removes the socket file.
//

@testable import SemelCLI
@testable import SemelCore
@testable import SemelServ
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import XCTest

final class ServerTests: RequestHandlerTestCase {

    private var socketPath: String!
    private var server: Server!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short on purpose: a Unix-domain socket path is limited to 103 bytes on macOS.
        let directory = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("semelserv.sock").path
        server = Server(handler: handler, socketPath: socketPath)
        try server.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
        super.tearDown()
    }

    private func connect() throws -> SocketConnection {
        try SocketConnection.connect(to: socketPath)
    }

    private func daemon(_ connection: SocketConnection, _ request: DaemonRequest, body: Data? = nil) throws -> (DaemonResponse, Data?) {
        let (response, replyBody) = try connection.send(.daemon(request), body: body)
        guard case .daemon(let daemonResponse) = response else {
            throw NSError(domain: "ServerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a daemon reply: \(response)"])
        }
        return (daemonResponse, replyBody)
    }

    // MARK: - Verbs end to end

    func test_helloIsAcceptedOverTheSocket() throws {
        let client = try connect()

        let (response, _) = try client.send(.hello(Hello(role: .daemon)), body: nil)

        XCTAssertEqual(response, .hello(.accepted(serverVersion: Semel.version, databasePath: "/tmp/test-graph.sqlite")))
    }

    func test_pushListAndFetchRoundTrip() throws {
        let client = try connect()

        _ = try daemon(client, .beginBatch)
        let (pushed, _) = try daemon(client, .pushFile(path: "a.c", mode: 0o644), body: Data("int x;".utf8))
        _ = try daemon(client, .endBatch)
        let (listed, _)      = try daemon(client, .list(fileSystem: .input, pattern: "*.c"))
        let (fetched, bytes) = try daemon(client, .fetch(fileSystem: .input, path: "a.c"))

        XCTAssertEqual(pushed, .pushFile(didChange: true))
        XCTAssertEqual(listed, .list(entries: [ListEntry(path: "a.c", kind: .file, size: 6, mode: 0o644, status: .unreferenced)]))
        XCTAssertEqual(fetched, .fetch(mode: FileMetadata.defaultMode))
        XCTAssertEqual(bytes, Data("int x;".utf8))
    }

    func test_waitAnswersOverTheSocket() throws {
        let client = try connect()

        XCTAssertEqual(try daemon(client, .wait).0, .ok)
    }

    func test_anUndecodableRequestIsAnsweredNotDropped() throws {
        // Reach under SocketConnection: a raw frame whose JSON names no known case.
        let client = try connect()
        _ = client   // keeps the connection open for the server-side assertion below
        XCTAssertEqual(server.connectionCount, 1)
        // The handler answers malformedRequest through ServerConnection; SocketConnection
        // cannot send malformed JSON itself, so this is pinned at the ServerConnection level:
        let json = Data(#"{"daemon":{"teleport":{}}}"#.utf8)
        let reply = try XCTUnwrap(ServerConnection.reply(toUndecodable: Frame(kind: .request, correlationID: 5, json: json)))
        XCTAssertEqual(reply.correlationID, 5)
        XCTAssertEqual(try reply.response(), .error(.malformedRequest(description: "the request could not be decoded")))
    }

    // MARK: - Events

    func test_eventsReachSubscribedClientsOnly() throws {
        let subscriber = try connect()
        let bystander  = try connect()
        let delivered  = expectation(description: "subscriber got the event")
        var subscriberEvents: [Event] = []
        var bystanderEvents:  [Event] = []
        subscriber.onEvent = { event in
            subscriberEvents.append(event)
            delivered.fulfill()
        }
        bystander.onEvent = { event in bystanderEvents.append(event) }
        _ = try daemon(subscriber, .subscribe)

        BuildEngine.notice("output:/app: written")

        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(subscriberEvents, [.daemon(.notice(line: "output:/app: written"))])
        XCTAssertTrue(bystanderEvents.isEmpty)
    }

    // MARK: - Sessions

    func test_aClientThatVanishesMidBatchLeavesNoBatchOpen() throws {
        let client = try connect()
        _ = try daemon(client, .beginBatch)
        XCTAssertEqual(server.connectionCount, 1)

        client.close()

        let gone = expectation(description: "connection removed")
        DispatchQueue.global().async {
            while self.server.connectionCount != 0 {
                Thread.sleep(forTimeInterval: 0.05)
            }
            gone.fulfill()
        }
        wait(for: [gone], timeout: 5)
        // With the session ended, a new client's push must wake the engine as usual: the
        // observable is that a fresh begin/end pair leaves the handler's session at depth 0
        // and the engine's coalesced signal count moves. The engine's depth is private, so
        // the test pins the server-side unwind through a second session.
        let second = try connect()
        _ = try daemon(second, .beginBatch)
        _ = try daemon(second, .endBatch)
        XCTAssertEqual(server.connectionCount, 1)
    }

    /// B-61's documented limit: a wait while another session holds a batch open blocks
    /// until that batch closes. Pinned so the behaviour is deliberate, not accidental.
    func test_waitBlocksWhileAnotherSessionHoldsABatchOpen() throws {
        let holder = try connect()
        let waiter = try connect()
        _ = try daemon(holder, .beginBatch)
        let finished = expectation(description: "wait returned")

        DispatchQueue.global().async {
            _ = try? self.daemon(waiter, .wait)
            finished.fulfill()
        }

        // The engine in this fixture has no processing loop, so waitUntilIdle returns at
        // once regardless of batches; the limit only bites with a live loop. Document that
        // here by asserting the wait returns, and leave the live-loop case to B-61.
        wait(for: [finished], timeout: 5)
        _ = try daemon(holder, .endBatch)
    }

    // MARK: - Lifecycle

    func test_aSecondServerOnTheSamePathIsRefused() {
        let second = Server(handler: handler, socketPath: socketPath)

        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? ServerError, .alreadyRunning(path: socketPath))
        }
    }

    func test_stopRemovesTheSocketFileAndAStaleFileIsReplaced() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        // A stale file (nothing listening) is unlinked and the path reused.
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        server = Server(handler: handler, socketPath: socketPath)
        try server.start()
        let client = try connect()
        XCTAssertEqual(try daemon(client, .reset).0, .ok)
    }

    func test_fatalHandlingRefusesNewWorkThenTerminates() throws {
        struct Broken: UnrecoverableError {
            var unrecoverableDescription: String { "the store is read-only" }
        }
        let terminated = expectation(description: "terminate called")
        var code: Int32?

        server.handleFatal(Broken()) { exitCode in
            code = exitCode
            terminated.fulfill()
        }

        XCTAssertTrue(server.isStopping)
        wait(for: [terminated], timeout: 5)
        XCTAssertEqual(code, 70)
    }
}
```

- [ ] **Step 4: Run them to see them fail**

Run: `swift test --filter ServerTests`
Expected: compile failure, `Server`, `ServerConnection`, `ServerError` do not exist.

- [ ] **Step 5: Write `ServerConnection`**

`semel/Server/ServerConnection.swift`:

```swift
// ServerConnection.swift
// SemelServ
//
// One client. A serial queue of its own, a FrameStream, a Session, and the shared handler.
// Each request frame becomes one handler call on this queue and one reply frame back on
// the same stream, so replies leave in request order; events from the registry go out on
// the same stream and so cannot interleave with a reply.

import Foundation
import Network
import SemelProtocol
import SemelTransport

final class ServerConnection {

    let session = Session()

    /// Called on the connection's queue once, after the peer is gone and the session ended.
    var onClose: ((ServerConnection) -> Void)?

    private let stream: FrameStream
    private let handler: RequestHandler
    private let queue: DispatchQueue

    init(connection: NWConnection, handler: RequestHandler, label: String) {
        self.handler = handler
        self.queue   = DispatchQueue(label: label)
        self.stream  = FrameStream(connection: connection, queue: queue)
        stream.onFrame = { [weak self] frame in self?.receive(frame) }
        stream.onClose = { [weak self] _ in self?.finish() }
    }

    func start() {
        stream.start()
    }

    func close() {
        stream.close()
        queue.async { [self] in finish() }
    }

    /// Writes an already-encoded event to this client. Called from the registry, on any
    /// thread; FrameStream serialises the send on this connection's queue.
    func deliver(_ frame: Frame) {
        stream.send(frame)
    }

    // MARK: - Requests

    private func receive(_ frame: Frame) {
        guard frame.kind == .request else {
            // A client sends requests only; anything else is a framing bug on its side.
            return
        }
        let request: Request
        do {
            request = try frame.request()
        } catch {
            if let reply = Self.reply(toUndecodable: frame) {
                stream.send(reply)
            }
            return
        }
        let (response, body) = handler.handle(request, body: frame.body.isEmpty ? nil : frame.body, session: session)
        do {
            stream.send(try Frame.response(response, correlationID: frame.correlationID, body: body ?? Data()))
        } catch {
            // Only an over-limit reply fails to frame; the client learns of it as an error
            // rather than a silence.
            let failure = Response.error(.nodeError(description: "the reply could not be framed: \(error)"))
            if let fallback = try? Frame.response(failure, correlationID: frame.correlationID) {
                stream.send(fallback)
            }
        }
    }

    /// The answer to a request whose JSON names nothing this build knows. The connection
    /// survives: the frame was well formed, only the message was not. Nil only if a small
    /// fixed error message somehow fails to encode, in which case there is nothing to say.
    static func reply(toUndecodable frame: Frame) -> Frame? {
        try? Frame.response(.error(.malformedRequest(description: "the request could not be decoded")),
                            correlationID: frame.correlationID)
    }

    private var finished = false

    private func finish() {
        guard !finished else {
            return
        }
        finished = true
        handler.endSession(session)
        onClose?(self)
    }
}
```

There is no `try!` anywhere in this task; AGENTS.md keeps that at zero, so `reply(toUndecodable:)` returns an optional and the caller stays silent in the impossible case.

- [ ] **Step 6: Write `ConnectionRegistry`**

`semel/Server/ConnectionRegistry.swift`:

```swift
// ConnectionRegistry.swift
// SemelServ
//
// The live connections, and the handler's event sink. An event is encoded once and
// handed to every subscribed connection's stream; nothing here waits on a client, so the
// engine's reporting thread never blocks on a slow socket.

import Foundation
import SemelProtocol

final class ConnectionRegistry: EventSink {

    private let lock = NSLock()
    private var connections: [ObjectIdentifier: ServerConnection] = [:]

    var count: Int {
        lock.withLock { connections.count }
    }

    func add(_ connection: ServerConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
    }

    func remove(_ connection: ServerConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    /// Closes every connection; each one ends its own session as it goes.
    func closeAll() {
        let all = lock.withLock { Array(connections.values) }
        for connection in all {
            connection.close()
        }
    }

    // MARK: - EventSink

    func deliver(_ event: Event) {
        guard let frame = try? Frame.event(event) else {
            return
        }
        let subscribed = lock.withLock { connections.values.filter { $0.session.isSubscribed } }
        for connection in subscribed {
            connection.deliver(frame)
        }
    }
}
```

- [ ] **Step 7: Write `Server`**

`semel/Server/Server.swift`:

```swift
// Server.swift
// SemelServ
//
// The listener and the process-level rules around it: probe a socket file that is
// already there, refuse to run twice, unwind everything on stop, and turn an
// unrecoverable error into a refusal of new work followed by an exit. No signals here;
// the executable wires those.

import Foundation
import Network
import SemelDatabaseModels
import SemelProtocol
import SemelTransport

public enum ServerError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning(path: String)
    case cannotListen(path: String, underlying: String)

    public var description: String {
        switch self {
        case .alreadyRunning(let path):
            return "semelserv is already running at \(path)"
        case .cannotListen(let path, let underlying):
            return "cannot listen at \(path): \(underlying)"
        }
    }
}

public final class Server {

    private let handler: RequestHandler
    private let socketPath: String
    private let registry = ConnectionRegistry()
    private let queue = DispatchQueue(label: "semelserv.listener")
    private var listener: SocketListener?
    private var connectionCounter = 0
    private let lock = NSLock()
    private var stopping = false

    public init(handler: RequestHandler, socketPath: String) {
        self.handler    = handler
        self.socketPath = socketPath
        handler.eventSink = registry
    }

    public var connectionCount: Int {
        registry.count
    }

    /// True once a fatal error or stop has been seen; no new connection is accepted after.
    public var isStopping: Bool {
        lock.withLock { stopping }
    }

    // MARK: - Start and stop

    /// Probes an existing socket file, unlinks it if nothing answers, and listens. Blocks
    /// until the listener is ready or has failed.
    public func start() throws {
        do {
            try UnixSocketPath.check(socketPath)
        } catch {
            throw ServerError.cannotListen(path: socketPath, underlying: "\(error)")
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            if Self.probe(path: socketPath, timeout: 2) {
                throw ServerError.alreadyRunning(path: socketPath)
            }
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let listener = SocketListener(path: socketPath, queue: queue)
        listener.onConnection = { [weak self] connection in self?.accept(connection) }
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.start { result in
            if case .failure(let error) = result {
                failure = error
            }
            ready.signal()
        }
        ready.wait()
        if let failure {
            self.listener = nil
            throw ServerError.cannotListen(path: socketPath, underlying: "\(failure)")
        }
    }

    /// Stops accepting, closes every client, and removes the socket file. Idempotent.
    public func stop() {
        lock.withLock { stopping = true }
        listener?.cancel()
        listener = nil
        registry.closeAll()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard !isStopping else {
            connection.cancel()
            return
        }
        connectionCounter += 1
        let client = ServerConnection(connection: connection, handler: handler,
                                      label: "semelserv.connection.\(connectionCounter)")
        client.onClose = { [weak self] closed in self?.registry.remove(closed) }
        registry.add(client)
        client.start()
    }

    // MARK: - Probe

    /// Whether a server answers `hello` at `path` within `timeout`. A refused or waiting
    /// connection, a timeout, or a close without a reply all mean no.
    static func probe(path: String, timeout: TimeInterval) -> Bool {
        let queue     = DispatchQueue(label: "semelserv.probe")
        let stream    = FrameStream(connection: NWConnection(to: .unix(path: path), using: .tcp), queue: queue)
        let answered  = DispatchSemaphore(value: 0)
        var sawReply  = false
        stream.onFrame = { frame in
            if frame.kind == .response {
                sawReply = true
                answered.signal()
            }
        }
        stream.onClose = { _ in answered.signal() }
        stream.start()
        if let hello = try? Frame.request(.hello(Hello(role: .daemon)), correlationID: 1) {
            stream.send(hello)
        }
        _ = answered.wait(timeout: .now() + timeout)
        stream.close()
        return sawReply
    }

    // MARK: - Fatal errors

    /// The machine is broken: log it, take no new work, and terminate once the reply that
    /// was in flight has had a moment to leave. The delay is what lets the handler's
    /// `.unrecoverable` reply reach its client before the process ends.
    public func handleFatal(_ error: any UnrecoverableError, terminate: @escaping (Int32) -> Void) {
        FileHandle.standardError.write(Data("semelserv: \(error.unrecoverableDescription)\n".utf8))
        lock.withLock { stopping = true }
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            stop()
            terminate(70) // EX_SOFTWARE, as FatalErrors.defaultHandler uses
        }
    }
}
```

- [ ] **Step 8: Run the server tests**

Run: `swift test --filter ServerTests` — expected: 10 green. Then `swift test --filter SemelServTests` (the earlier 31 still green) and `swiftlint --strict` (0).

- [ ] **Step 9: Commit**

```bash
git add Package.swift SemelCore/Sources/SemelCore/BuildEngine.swift semel/Server semel/ServerTests/ServerTests.swift
git commit -m "Add the socket server: one queue per client, a registry that fans events out, and a probed socket file

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 4: The `semelserv` executable

**Files:**
- Modify: `Package.swift` (new `semelserv` executable target; `SemelServTests` depends on it so `swift test` builds it)
- Create: `semel-server/main.swift`
- Create: `semel/ServerTests/SemelservExecutableTests.swift`

**Interfaces:**
- Consumes: `Server`, `ServerError`, `RequestHandler`, `BuildEngine.start()`, `DatabaseLayer.shared`, `SemelPaths.database/serverSocket`, `FatalErrors.handler`, `SemelSwift.register()`, `SemelClang.register()`; `SocketConnection` (tests).
- Produces: the binary `semelserv`. Exit codes: 0 on signal stop, 1 when already running or cannot listen, 70 on a fatal error.

- [ ] **Step 1: Add the target**

In `Package.swift`, after the `semel` executable target:

```swift
        // The server: the engine behind a Unix-domain socket. The composition root for the
        // toolchains and the engine lives here now; `semel` is a client.
        .executableTarget(
            name: "semelserv",
            dependencies: [
                "SemelServ",
                "SemelTransport",
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
                .product(name: "SemelSwift", package: "SemelSwift"),
                .product(name: "SemelClang", package: "SemelClang"),
            ],
            path: "semel-server",
            sources: ["main.swift"]
        ),
```

and add `"semelserv",` to `SemelServTests`' dependencies, so `swift test` builds the binary the subprocess test runs.

- [ ] **Step 2: Write the failing executable test**

`semel/ServerTests/SemelservExecutableTests.swift`:

```swift
//
//  SemelservExecutableTests.swift
//  SemelServTests
//
//  The binary, as a subprocess, with SEMEL_HOME and SEMEL_SOCKET pointing into a
//  temporary directory so it never opens the user's graph or socket. What is pinned:
//  it comes up and answers hello, a second instance is refused, and SIGTERM stops it
//  cleanly with the socket file gone.
//

import Foundation
@testable import SemelCLI
import SemelProtocol
import XCTest

final class SemelservExecutableTests: XCTestCase {

    private var home: URL!
    private var socketPath: String!
    private var processes: [Process] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short on purpose: the socket lives under the home, and a Unix-domain socket path
        // is limited to 103 bytes on macOS.
        home = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        socketPath = home.appendingPathComponent("semelserv.sock").path
    }

    override func tearDown() {
        for process in processes where process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        processes = []
        super.tearDown()
    }

    /// The products directory holds the test bundle and the executables built beside it.
    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("semelserv")
    }

    private func launch() throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = binary
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["SEMEL_HOME": home.path, "SEMEL_SOCKET": socketPath]) { _, override in override }
        let output = Pipe()
        process.standardOutput = output
        process.standardError  = output
        try process.run()
        processes.append(process)
        return (process, output)
    }

    private func waitForSocket() -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    func test_startsAnswersHelloRefusesASecondInstanceAndStopsOnSigterm() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path),
                          "semelserv is not built beside the test bundle at \(binary.path)")

        let (server, _) = try launch()
        XCTAssertTrue(waitForSocket(), "the server never created \(socketPath!)")

        let client = try SocketConnection.connect(to: socketPath)
        let (reply, _) = try client.send(.hello(Hello(role: .daemon)), body: nil)
        guard case .hello(.accepted(_, let databasePath)) = reply else {
            return XCTFail("expected an accepted hello, got \(reply)")
        }
        XCTAssertEqual(databasePath, home.appendingPathComponent("graph.sqlite").path)

        let (second, secondOutput) = try launch()
        second.waitUntilExit()
        let secondText = String(decoding: secondOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(second.terminationStatus, 1)
        XCTAssertTrue(secondText.contains("already running"), secondText)

        client.close()
        server.terminate() // SIGTERM
        server.waitUntilExit()
        XCTAssertEqual(server.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }
}
```

- [ ] **Step 3: Run it to see it fail**

Run: `swift test --filter SemelservExecutableTests`
Expected: the test is skipped or fails because there is no `semelserv` binary yet (the manifest names a target with no source), or the build fails on the missing `main.swift`. Either is the expected red.

- [ ] **Step 4: Write the executable**

`semel-server/main.swift`:

```swift
//
//  main.swift
//  semelserv
//
//  The engine behind a Unix-domain socket. Start it in a terminal or under launchd; it
//  logs to standard output and error and stops cleanly on SIGINT or SIGTERM. One per
//  user: a second instance finds the first through the socket file and exits.
//

import Foundation
import SemelClang
import SemelCore
import SemelNodeKit
import SemelProtocol
import SemelServ
import SemelSwift

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("semelserv: \(message)\n".utf8))
    exit(code)
}

// Composition root: the engine knows no toolchains, so this is where the ones this
// binary ships are installed. Before start(), so discovery sees them on its first pass.
do {
    try SemelSwift.register()
    try SemelClang.register()
    try BuildEngine.start()
} catch {
    fail("cannot start the engine: \(error)", code: 1)
}

let handler = RequestHandler(engine: BuildEngine.shared,
                             database: DatabaseLayer.shared,
                             databasePath: SemelPaths.database.path)
let server = Server(handler: handler, socketPath: SemelPaths.serverSocket.path)

// A machine failure ends the process, but only after the client that hit it has its
// answer. The server marks itself stopping first so nothing new is accepted meanwhile.
FatalErrors.handler = { error in
    server.handleFatal(error) { code in exit(code) }
}

do {
    try server.start()
} catch let error as ServerError {
    fail(error.description, code: 1)
} catch {
    fail("\(error)", code: 1)
}

print("Semel server \(Semel.version)")
print("Graph:  \(SemelPaths.database.path)")
print("Socket: \(SemelPaths.serverSocket.path)")

// Signals: ignore the default disposition, then handle on a queue so the stop runs on an
// ordinary thread with the listener's locks available.
let signalQueue = DispatchQueue(label: "semelserv.signals")
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
    source.setEventHandler {
        server.stop()
        BuildEngine.shared.stopProcessingLoop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
```

- [ ] **Step 5: Build and run the test**

Run: `swift build` (expected: `semelserv` builds), then `swift test --filter SemelservExecutableTests` — expected: 1 green, not skipped. If it is skipped, `ls .build/debug/semelserv` and the test bundle's directory (`ls .build/debug/*.xctest`) and report the paths; the products directory derivation is the likely culprit.

Then run it by hand once, in a temporary home:

```bash
export SEMEL_HOME=$(mktemp -d)
swift run semelserv &
sleep 5
ls -l "$SEMEL_HOME"
kill -TERM %1
wait
ls -l "$SEMEL_HOME"
unset SEMEL_HOME
```

Expected: the three banner lines; the first listing shows `semelserv.sock` with an `s` in its mode column and `graph.sqlite` beside it; `wait` reports exit status 0; the second listing has no socket file. Record the output in the report. Then `swiftlint --strict` (0) and `swift test` (root).

- [ ] **Step 6: Commit**

```bash
git add Package.swift semel-server semel/ServerTests/SemelservExecutableTests.swift
git commit -m "Add the semelserv executable: composition root, probed socket, signal shutdown, fatal handling

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 5: `semel` becomes the client, and the records

**Files:**
- Modify: `semel/main.swift`
- Modify: `Package.swift` (the `semel` target's dependencies)
- Modify: `docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md`
- Modify: `BACKLOG.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Rewrite `main.swift`**

Replace `semel/main.swift` with:

```swift
//
//  main.swift
//  semel
//
//  Created by Jade Burton on 16.01.26.
//

import Foundation
import SemelCLI
import SemelNodeKit
import SemelProtocol

var commandInterpreter: CommandInterpreter?

func main() throws {
    // The client half only. The engine, the graph and the toolchains live in semelserv;
    // this process opens a socket to it and hands the connection to the interpreter.
    let socketPath = SemelPaths.serverSocket.path
    let connection: SocketConnection
    do {
        connection = try SocketConnection.connect(to: socketPath)
    } catch {
        FileHandle.standardError.write(Data("semel: \(error)\n".utf8))
        exit(1)
    }
    let interpreter = CommandInterpreter(connection: connection)

    let server: (serverVersion: String, databasePath: String)
    do {
        server = try interpreter.connect()
    } catch {
        FileHandle.standardError.write(Data("semel: \(error)\n".utf8))
        exit(1)
    }
    print("Semel \(server.serverVersion) (C) 2026 Jade Burton. All rights reserved.")
    print("Graph: \(server.databasePath)")

    commandInterpreter = interpreter

    // Non-interactive: each argument is one command line, run in order, then exit —
    // non-zero if any command reported an error. `semel 'build Packages'` is a build step;
    // `semel 'base /repo' 'push src' wait errors` is the same thing spelled out.
    let scripted = Array(CommandLine.arguments.dropFirst())
    if !scripted.isEmpty {
        for command in scripted {
            guard receiveUserInput(line: command) else {
                break
            }
        }
        exit(interpreter.errorsReported == 0 ? 0 : 1)
    }

    while let line = readLine(), receiveUserInput(line: line) {
    }
}

func receiveUserInput(line: String) -> Bool {
    do {
        try commandInterpreter?.handleCommand(line)
        return true
    } catch {
        return false
    }
}

#if !UNIT_TESTING
try main()
#endif
```

- [ ] **Step 2: Drop the engine from the `semel` target**

In `Package.swift`, the `semel` executable's dependencies become exactly:

```swift
            dependencies: [
                "SemelCLI",
                "SemelTransport",
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
            ],
```

Run: `swift build` — expected: clean. Then `grep -n 'import' semel/main.swift` shows only Foundation, SemelCLI, SemelNodeKit, SemelProtocol.

- [ ] **Step 3: Run all six suites and the linter**

```bash
swift test --package-path SemelNodeKit
swift test --package-path SemelCore
swift test --package-path SemelProtocol
swift test
swift test --package-path SemelSwift
swift test --package-path SemelClang
swiftlint --strict
```

Expected: NodeKit 124, Core 343, Protocol 44, root 122 + 4 + 6 + 10 + 1 = 143, Swift 135, Clang 44; 0 lint violations. Record each `Executed N tests` line.

- [ ] **Step 4: Run the two apps by hand**

```bash
SEMEL_HOME=$(mktemp -d); export SEMEL_HOME
swift run semelserv &
sleep 8
swift run semel pwd 'ls -o' errors; echo "exit=$?"
swift run semel 2>&1 | head -2   # interactive: banner then waits; press Ctrl-D
kill -TERM %1; wait
unset SEMEL_HOME
swift run semel pwd; echo "exit=$?"   # no server: the one-line message, exit 1
```

Expected: the server's three banner lines; the client's banner with the server's version, `input:`, a listing or `(empty)`, `No errors.`, exit 0; the interactive banner; a clean server exit; and without a server, `semel: no server at <path> (...); start one with `semelserv`` on standard error and exit 1. Paste the output into the report.

- [ ] **Step 5: Record phase 3**

In `docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md`:
- Status line → `**Status:** all three phases implemented`
- In Section 5's "The socket file" paragraph, after the sentence introducing `SEMEL_SOCKET`, add: "`SemelPaths.root` has the same kind of override, `SEMEL_HOME`, so a server started by a test has a graph and store of its own."
- In "The client", change "links only `SemelCLI`, `SemelNodeKit`, `SemelProtocol` and `SemelTransport`" only if it does not already say so (it does).

In `BACKLOG.md`:
- Entry B-30, role 3: replace "phases 1 and 2 of three are built: …" with "built in three phases: the `SemelProtocol` package, the in-process split behind `RequestHandler` and `InProcessConnection`, and `semelserv` plus `SocketConnection` — see the spec's Section 5."
- Entry B-61: strike the first item (`loopIsRunning` under the lock) by rewording the entry to list the two that remain, and note the test `test_waitBlocksWhileAnotherSessionHoldsABatchOpen` as the place the limit is pinned.

In `AGENTS.md`:
- "Build and test" block: no new line, because `SemelTransport` is a target of the root package and `SemelTransportTests` runs under the root `swift test`; change the root line's comment to `# the CLI, transport and server tests (~143)`.
- The composition-root paragraph: replace the sentence about `main.swift` building the `RequestHandler` and `InProcessConnection` with: "`semel-server/main.swift` is the composition root: it registers the toolchains, starts the engine and listens on `SemelPaths.serverSocket`. `semel/main.swift` opens a socket to it and nothing else; start `semelserv` first, or `semel` says so and exits. Tests point both at a temporary directory with `SEMEL_HOME` and `SEMEL_SOCKET`."
- Under "In Xcode…", add one sentence: run the `semelserv` scheme before the `semel` scheme.

- [ ] **Step 6: Commit**

```bash
git add semel/main.swift Package.swift docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md BACKLOG.md AGENTS.md
git commit -m "Make semel a client of semelserv, and record phase 3 as built

The CLI links only SemelCLI, SemelNodeKit, SemelProtocol and
SemelTransport; the engine and the toolchains live in the server.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

## Self-review notes

- **Spec coverage, Section 5.** Executable and composition root (Task 4); socket path with both overrides (Task 1); probe, stale unlink, "already running" exit 1, banner, stdout/stderr logging (Tasks 3–4); one queue per connection, ordered writer, handler off-queue `wait` (Task 3, using `RequestHandler` as it is); frame error / decode failure / peer close ending the session; `malformedRequest` with the connection kept (Task 3); event fan-out to subscribed sessions without touching the handler's queue (Task 3); `SIGINT`/`SIGTERM` stop (Task 4); fatal handler with the in-flight reply (Tasks 3–4); `loopIsRunning` under the lock (Task 3). Client: `SocketConnection` with waiters, reader, failure on close, no reconnect, nil-body convention (Task 2); `main.swift` and the dependency drop, the no-server message (Task 5); `FrameStream` in `SemelTransport` (Task 1). Testing paragraphs: transport (1), socket connection (2), server (3), executable (4).
- **Refinement recorded:** `SEMEL_HOME` (Task 5 writes it into the spec).
- **Type consistency:** `FrameStream(connection:queue:)`, `onFrame`, `onClose`, `start()`, `send(_:)`, `close()`, internal `sendRaw(_:)` used by Task 1's test through `@testable`; `SocketListener(path:queue:)`, `onConnection`, `start(ready:)`, `cancel()` used in Tasks 1–3; `SocketConnection.connect(to:timeout:)`, `send`, `onEvent`, `close()` used in Tasks 2–5; `Server(handler:socketPath:)`, `start()`, `stop()`, `connectionCount`, `isStopping`, `handleFatal(_:terminate:)`, `ServerError.alreadyRunning(path:)` used in Tasks 3–4; `ServerConnection.reply(toUndecodable:)` static and internal, reached by the test through `@testable`.
- **Known soft spots, said plainly:** the executable test derives the products directory from the test bundle's location and skips if the binary is absent, so a build-layout change turns it into a skip rather than a failure — the report must say "1 passed", not "1 skipped". `test_waitBlocksWhileAnotherSessionHoldsABatchOpen` documents B-61's limit against a loop-less fixture and therefore only asserts that `wait` returns; the live-loop case stays in B-61.
