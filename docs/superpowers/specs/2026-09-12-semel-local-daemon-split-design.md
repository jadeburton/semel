# Splitting Semel into a local daemon and a CLI

**Status:** phases 1 and 2 implemented; phase 3 not yet started
**Date:** 2026-09-12
**Relationship:** this is B-30 role 3, the local build daemon. It takes the frame design
and the surviving parts of `2026-08-15-semel-client-server-design.md` and drops everything
that document needed for a shared, multi-user server. The cache server
(`2026-08-15-semel-cache-server-design.md`, B-30 role 1) is not built here, but the wire
model is shaped so that it can be, as a second role on the same protocol.

## What this is

Semel is one process today: a REPL that owns the build engine, the graph database and the
object store, and whose command plugins walk the node graph directly. This splits it into
`semelserv`, a long-running local server that owns all of that, and `semel`, a CLI that
reaches it over a socket. One user, one graph, one machine. Several CLIs may be connected
at once: the point of the daemon is a build that continues regardless of which terminals
are open.

The work is in three phases, each of which builds and passes on its own:

1. **`SemelProtocol`** — a new package holding the frame codec and every message that
   crosses the wire. Nothing else changes.
2. **The in-process split** — the code is divided into client and server halves that talk
   only through the wire objects, but still run in one process. The socket is "pretended"
   by a bottleneck function.
3. **Two apps** — the socket is added and the halves become two executables.

## Non-goals

Named explicitly because each was discussed and deliberately cut:

- **Multiple users.** No path authorisation, no per-user home directories, no
  reconciliation, no working-copy sync. Those belonged to the shared-build-server model
  the cache-server spec superseded.
- **Auto-launching the server.** A CLI that finds no server says so and how to start one.
  Launching it from the CLI is a later backlog item.
- **Authentication.** `Hello` has no credentials. The server listens on a Unix domain
  socket in the user's own application support directory.
- **B-50 settle diffs as events.** The event kind exists and carries what the engine
  reports today. Settle diffs become a new event case when B-50 is built.
- **Chunked or compressed bodies.** The flags byte is reserved for them.
- **The cache and runner roles themselves.** Only the room for them.

## Module layout

```
SemelDatabaseModels   unchanged
SemelNodeKit          gains the wildcard matcher and its external lister from SemelCore
SemelCore             three small changes: reporter closures, ErrorReport split,
                      string-returning graph dump (see "Changes to SemelCore");
                      InternalFileSystemLister keeps the graph-backed lister
SemelProtocol   NEW   package: frame codec + message types + the SemelConnection
                      protocol. Depends on Foundation only.
SemelServ       NEW   library target in the root package: RequestHandler, Session,
                      event sink, InProcessConnection. Owns BuildEngine + DatabaseLayer.
                      No sockets.
SemelCLI              keeps CommandInterpreter and plugins; CommandContext holds a
                      SemelConnection instead of DatabaseLayer / BuildEngine
semelserv       NEW   executable (phase 3): composition root + listener
semel                 executable: REPL, session state, local disk I/O, SocketConnection
```

Dependency direction, which is the test of whether the seam is in the right place:

```
SemelCore  ◀──  SemelServ  ──▶  SemelProtocol  ◀──  SemelCLI
```

`SemelCore` learns nothing about the protocol. `SemelCLI` learns nothing about the engine.
`SemelProtocol` learns nothing about either.

## Section 1: the `SemelProtocol` package

### Layout

A new SwiftPM package at `SemelProtocol/`, a peer of `SemelCore` and `SemelNodeKit`, added
to `Semel.xcworkspace`. One library target, one test target. It imports Foundation only.
Paths, hashes and modes cross the wire as strings and integers, so nothing in it knows
about nodes, the database or GRDB.

The no-dependency rule is deliberate and has a cost, which is paid on purpose: anything
the engine wants to send is *mirrored* as a wire struct and mapped in `SemelServ`, never
imported. The wire format is therefore independent of the persisted schema, so a database
change is not silently a protocol change, and a client that speaks only one role does not
link GRDB.

### The frame

The August frame, kept as designed. All integers big-endian.

```
offset  size  field
─────────────────────────────────────────────
  0      1    version         1
  1      1    kind            1=request 2=response 3=event
  2      1    flags           reserved (chunking, compression)
  3      1    reserved
  4      8    correlationID   UInt64, echoed in the response; 0 for events
 12      4    jsonLength      UInt32
 16      8    bodyLength      UInt64
 24      …    json bytes      may be empty
  …      …    body bytes      raw, may be empty
```

**Both sections in one frame.** `pushFile` is metadata plus bytes; `fetch`'s reply is
metadata plus bytes. One frame per operation per direction keeps blobs out of JSON — no
base64, no inflation — and avoids two frames tied by correlation ID with the failure mode
of one arriving without the other.

**The message type is not in the header.** It is the enum case inside the JSON. A second
discriminator in the header would be two sources of truth for one question.

**No magic bytes.** The transport already gives ordered, integrity-checked delivery. A
desync would be our own framing bug.

**Two version fields, deliberately.** The frame's `version` byte governs framing and is
checked before anything is decoded; a mismatch closes the connection because nothing
further can be trusted. `Hello.protocolVersion` governs the message set and is negotiated
once framing is known to work, so a mismatch is reported as a clean rejection.

### The codec

- `Frame` — a value holding `kind`, `correlationID`, `json: Data`, `body: Data`.
- `FrameEncoder.encode(_ frame: Frame) -> Data`.
- `FrameDecoder` — fed bytes incrementally with `append(_ bytes: Data)`, yields complete
  frames with `next() throws -> Frame?`. A socket delivers whatever it delivers, so the
  decoder must be happy with half a header.
- Limits are constants in the package: `maximumJSONLength` = 1 MB,
  `maximumBodyLength` = 512 MB. Declared lengths are checked against them *before*
  anything is allocated.
- A wrong version byte or an over-limit length throws `FrameError` — a hard failure, the
  connection closes. An unknown enum case inside the JSON is a soft failure: the decoder
  hands back the frame, the JSON decode fails, and the server answers with an error
  response on the same correlation ID.

### Message types, grouped by role

Three Codable enums: `Request`, `Response`, `Event`. Each is an enum **of roles**, and
each role is an enum of messages whose payloads are their own structs, so a request that
grows a field does not disturb its neighbours:

```swift
public enum Request: Codable {
    case hello(Hello)
    case daemon(DaemonRequest)
    // case cache(CacheRequest)      — B-30 role 1, a new file when it arrives
    // case runner(RunnerRequest)    — B-30 role 2
}
```

As built, a payload is a set of *labelled associated values* on the case rather than a
separate struct. Swift's synthesized Codable turns each label into a JSON key, which gives
the same per-case isolation with field names on the wire instead of positional `_0` keys.
Records that several cases share — `ListEntry`, `ErrorRecord`, `ToolNamespace` — are
structs.

Which role a message belongs to is then a type-level fact. Adding a role is a new file
rather than an edit to every switch, and a server that does not offer a role rejects the
whole group with one error case. `Response` and `Event` group the same way, with
`Response` additionally carrying the role-independent `.error(ErrorResponse)` and
`.hello(HelloResponse)`.

### The daemon role

| Request | Payload | Body | Reply |
|---|---|---|---|
| `list` | fileSystem, pattern | | `[ListEntry]` |
| `beginBatch` / `endBatch` | | | ok |
| `pushFile` | path, mode | file bytes | didChange |
| `pushFolder` | path | | ok |
| `remove` | pattern | | the removed paths |
| `fetch` | fileSystem, path | | mode; file bytes in body |
| `errors` | | | `[ErrorRecord]` |
| `tools` | | | `[ToolNamespace]` |
| `reset` / `nudge` | | | ok |
| `debug` | | | the graph as one string |
| `subscribe` | | | ok |

- `fileSystem` is `input` or `output`. `pattern` and `path` are absolute within that file
  system, already resolved by the client against its current directory: the server never
  sees `..`.
- `ListEntry` carries `path`, `kind` (file or folder), `size?`, `mode?` and a `status` of
  `none`, `missing`, `unreferenced`, `pending` or `error`. That is exactly what `ls`
  prints today, so the plugin's formatting survives untouched.
- `ErrorRecord` carries the node `label` and `entries: [(ports: [String], message: String)]`,
  the shape `ErrorReport` already groups by.
- `ToolNamespace` carries `namespace`, `toolName`, and `descriptors`, each with `name`,
  `version`, `platform`, `architecture` and `machineSettings: [String: String]` — what
  `tools` prints today, unrendered.
- `pushFile` sends **no hash**. Hashing lives in `SemelNodeKit`, and a package with no
  dependencies cannot compute it, so the server interns the bytes and hashes them itself.
  This is a daemon-role decision only: the cache role is *keyed* by hash strings, computed
  by the engine, which does link `SemelNodeKit`.
- There are no manifests, batches keyed by correlation ID, or unknown-hash handshakes.
  They existed for pushing to a remote server over a slow link. `beginBatch` and
  `endBatch` survive only because the engine's batch coalescing needs to bracket a
  multi-file push.

### `Hello`

```
Hello          protocolVersion, role (daemon | cache | runner)
HelloResponse  accepted(serverVersion, databasePath)
             | rejected(reason: versionMismatch(client, server) | roleNotOffered(role))
```

The client names the service it wants; the server answers with what it offers. One
`semelserv` binary in three modes was the backlog's shape; this is the handshake that
makes it so. `databasePath` is in the reply because `main.swift` prints "Graph: …" from
local state today and the CLI no longer has that state.

### Events

```swift
public enum DaemonEvent: Codable {
    case errors([ErrorRecord])   // the idle-time error report
    case notice(String)          // unclaimed config keys, artifact status lines
}
```

Events use correlation ID zero and go to every connection that sent `subscribe`. They
carry what the engine prints from its background task today, and nothing more; B-50's
settle diffs become a third case.

### Error responses

```swift
public enum ErrorResponse: Codable {
    case pathNotFound(path: String)
    case notAFolder(path: String)
    case nodeError(description: String)
    case roleNotOffered(role: Role)
    case malformedRequest(description: String)
    case unrecoverable(message: String)
}
```

Parse errors — unknown verb, missing argument — stay on the client, where they occur.
Build errors are data, not protocol errors: a node that fails to compile comes back from
`errors`, mirroring the existing distinction between a node failure and an
`UnrecoverableError`.

## Section 2: the server side, `SemelServ`

### A library first, an executable later

`SemelServ` is a library target in the root package, importing `SemelCore` and
`SemelProtocol`. In phase 2 the existing `semel` executable links it. In phase 3 the
`semelserv` executable becomes the composition root: it registers the toolchains, starts
the engine, opens the listener. The library never touches sockets, so it is tested with
nothing but an in-memory `DatabaseLayer`.

### The bottleneck

One type, `RequestHandler`, with one entry point:

```swift
func handle(_ request: Request, body: Data?, session: Session) -> (Response, Data?)
```

It holds the engine and the database, handed in at construction as the interpreter is
today; the process-wide singletons are resolved once, in the composition root. Every case
of `DaemonRequest` maps to one private method. The handlers are the graph-touching halves
of today's plugins, moved across largely unchanged:

- `list` runs `FileWildcardMatcher` over `InternalFileSystemLister` and reads each file's
  hash, size and mode for the entry.
- `pushFile` calls `ensureEntirePathExistsAsFolders`, finds or creates the `StaticFile`,
  interns the body, calls `replaceContent`.
- `pushFolder` calls `ensureEntirePathExistsAsFolders(…, pinned: true)`.
- `remove` matches and calls `deleteInInputFileSystem` on each `UserDeletable`.
- `fetch` resolves the hash and returns bytes and mode.
- `errors` builds records from `selectAllErrors()` via the gathering half of `ErrorReport`.
- `tools` reads `ToolRunnerRegistry` and `ToolNamespaceRegistry` — they are registered in
  the composition root, which is the server.

### Per-connection state

A `Session` the handler is given alongside each request: whether it has subscribed, and
its open batch depth. In phase 2 there is exactly one. In phase 3 there is one per
connection, and tearing a connection down calls `endBatch` for each level it left open, so
a CLI killed mid-push cannot leave the engine suppressed forever.

### Serialisation

Requests are handled on one serial queue, which is the role the REPL thread plays today
against the engine's background task. GRDB's `dbQueue` and the existing task-local
transaction nesting already make that safe. Two CLIs issuing commands at once take turns.

The queue is serial, but the *protocol* is not: correlation IDs allow several requests in
flight on one connection. Matching replies to requests is the connection's job, not the
handler's, and the connection tests exercise it even though no CLI verb needs it. See
"Concurrent requests" in Section 4.

### Routing the engine's reports

`BuildEngine` gets two closures beside the existing `unclaimedConfigKeyReporter`:

- `errorReporter: ([ErrorReport.Entry]) -> Void` — receives structured entries from
  `reportIdleTimeErrors` instead of that method printing lines.
- `noticeReporter: (String) -> Void` — `OutputFile` and `ProjectBuilder` stop calling
  `print` directly and go through it.

The defaults still print, so the engine tests and the phase 2 single-process build behave
as they do now. The server installs closures that convert to `Event` values and hand them
to an `EventSink`, a protocol with one method. In phase 2 the sink forwards straight to the
interpreter; in phase 3 it fans out to subscribed connections.

### Changes to `SemelCore`

Four, all small, all in service of the seam:

1. **`ErrorReport` splits** into gathering and rendering. `ErrorReport.entries(forNodeID:ports:messages:database:)`
   returns `[Entry]` (label, grouped ports and messages) and stays in Core. Rendering
   entries to lines is duplicated: `ErrorReport.lines(for:)` stays in Core for the default
   reporter and is pinned by `ErrorReportTests`, and `ErrorRecordRenderer` in `SemelCLI`
   renders the wire record identically, because the CLI cannot import Core and the
   protocol package must not render.
   The one-shape-for-both-callers property the file's header comment describes is kept:
   both the event and the `errors` reply are `ErrorRecord`s rendered by one function.
2. **`printAll` returns a string** rather than printing, so `debug` can be a response.
3. **The reporter closures** above.
4. **The wildcard matcher moves to `SemelNodeKit`.** `push` walks the local disk with
   `FileWildcardMatcher` and `ExternalFileSystemLister`, and the CLI must do that without
   linking the engine. Only `InternalFileSystemLister` needs `NodeRecord`, so only it stays.

### Unrecoverable errors

Today `FatalErrors` halts the process. In the server that stays true: a store that cannot
be written belongs to the machine, and answering one connection with an error would be
reporting it to whoever happened to trigger it. The handler answers the in-flight request
with `unrecoverable`, the server logs it and exits, and every CLI sees its connection
close. Restarting the server is the recovery, as restarting `semel` is today.

## Section 3: the client side

### `CommandContext` loses the engine

It keeps the session state — base directory, current file system, current directory
path — plus the output closures and the path resolver. `database`, `buildEngine`,
`inputFileSystem` and `outputFileSystem` go. In their place:

```swift
public protocol SemelConnection: AnyObject {
    func send(_ request: Request, body: Data?) throws -> (Response, Data?)
    var onEvent: ((Event) -> Void)? { get set }
}
```

`send` is synchronous and thread-safe: it blocks the calling thread until the reply
matched to its request arrives, and several threads may have sends outstanding at once.
Events arrive on `onEvent`, called from whatever thread the connection receives on; the
interpreter installs one handler at startup and prints with the same renderers the verbs
use. `CommandInterpreterError.quit` and `CommandParserError` stay where they are.

**Synchronous, deliberately, and kept small so it can become async later.** The REPL is
a `readLine` loop, every plugin's `handle` is synchronous, and the engine's cache hooks
that the cache role will call are synchronous too; an `async` connection would push
`async` through all of them for a client that sends one request at a time. The protocol
is therefore exactly two members, and all request matching lives inside the conformers,
so an async variant is a change to one protocol's signatures and its conformers, never to
a plugin.

**The protocol lives in `SemelProtocol`**, not in `SemelCLI`, because of the dependency
rule: `InProcessConnection` holds a `RequestHandler`, so if the protocol were the CLI's,
either the CLI would import the server or the server the CLI. In the protocol package it
is what it describes — a thing that carries `Request`s and returns `Response`s — and both
sides can see it without seeing each other.

### Plugins split cleanly

Parsing, flag handling, path resolution against the current directory, and formatting all
stay. The graph work becomes a request:

| Verb | Requests |
|---|---|
| `ls` | `list`; if exactly one folder matched, a second `list` of `folder/*` (the display rule stays client-side) |
| `cd` | `list` for the target; requires exactly one folder result |
| `pwd` | none |
| `push` | walks the local disk as now; then `beginBatch`, one `pushFile` or `pushFolder` per entry, `endBatch` |
| `cp` | `list` for the pattern, then `fetch` per file; writes bytes and `chmod`s locally |
| `rm` | `remove` |
| `errors`, `tools`, `reset`, `nudge`, `debug` | one request each; the CLI renders the reply |
| `base`, `quit`, `begin`, `commit`, `discard` | never leave the process |

`push` keeps its "decide the whole work list before pushing any of it" rule; only the
per-entry action changes from a direct graph call to a request.

### Startup

The REPL sends `hello(role: .daemon)` first and prints the server version and graph path
from the reply. Then it sends `subscribe`. A rejection is printed with both versions, or
the role, and the CLI exits.

### Connections

- `InProcessConnection` (phase 2, in `SemelServ`) — holds a `RequestHandler` and a
  `Session`. It does **not** hand Swift objects across: every request is encoded to a
  `Frame` and decoded again before the handler sees it, and every reply goes back through
  the same pair. The day the socket arrives, the codec and the model have already been
  exercised by every CLI test. Its `onEvent` is fed directly by the handler's event sink.
- `SocketConnection` (phase 3, in `SemelCLI`) — Network.framework over a Unix domain
  socket. Writes frames; reads with a `FrameDecoder`; matches replies to waiting callers
  by correlation ID; delivers event frames to `onEvent`.

## Section 4: room for the cache server

The cache server is not built here. The wire model is shaped so that building it adds to
the protocol rather than reshaping it.

**What the cache role will need.** The engine's cache has two hooks —
`loadCachedOutputs(cacheKey:)` and `saveCacheForAllInputsAndOutputs(…)` — and an entry
holds object hashes rather than bytes. So the role is five messages: look up an entry,
store an entry, ask which of these hashes you hold, get a blob, put a blob. The last two
carry bodies, which is what the raw body section is for.

**Role grouping** (Section 1) is the structural provision: `CacheRequest`, `CacheResponse`
and, if wanted, `CacheEvent` are new files, and `Hello` already negotiates the role.

**Concurrent requests from day one.** A REPL sends one request at a time, but an engine
with twenty nodes finishing at once will make twenty cache lookups in flight, each from
its own thread. So `SemelConnection.send` is designed around the correlation ID from the
start: it returns the reply matched to its request, and several threads may have sends
outstanding. Both the in-process and the socket connection honour this, and their tests
cover interleaved requests even though no CLI verb produces them. That the calls are
synchronous is what the engine's cache hooks want today; if the engine ever becomes
async, the two-member protocol is the whole surface that changes.

**Cache payloads are mirrored, not imported.** A cache entry on the wire is a struct in
`SemelProtocol` that `SemelServ` maps to and from `ProcessCacheEntry`, and hashes are
strings. This follows from the no-dependency rule and is the reason for it.

**The frame's reserved bits stop being theoretical.** `flags` keeps its reserved meaning
for compression and chunked bodies, which matter once a multi-megabyte artifact crosses a
real network rather than a local socket. `version` covers a framing change. Neither is
built now.

## Phases

### Phase 1: `SemelProtocol`

The package, the frame codec, the message types, their tests. Added to the workspace.
Nothing else in the repository changes. Done when `swift test --package-path SemelProtocol`
is green.

### Phase 2: the in-process split

- `SemelProtocol`: the `SemelConnection` protocol.
- `SemelServ` library: `RequestHandler`, `Session`, `EventSink`, and `InProcessConnection`
  round-tripping through the codec.
- `SemelCore`: the three changes above.
- `SemelCLI`: `CommandContext` moves to `SemelConnection`; plugins send requests; the
  `ErrorReport` renderer and the `tools` renderer live here.
- `main.swift` still registers toolchains and starts the engine, then builds a
  `RequestHandler`, an `InProcessConnection`, and the interpreter on top. One process,
  behaviour unchanged.
- The existing `SemelCLITests` are converted to construct an in-process connection.

Done when all six test suites are green and the REPL behaves as before.

### Phase 3: two apps

- `semelserv` executable: composition root plus an `NWListener` on a Unix domain socket at
  `SemelPaths.root/semelserv.sock`. One `Session` per connection; the event sink fans out.
- `SocketConnection` in `SemelCLI`.
- The `semel` executable drops `SemelCore`, `SemelSwift` and `SemelClang` and links only
  `SemelCLI` and `SemelProtocol`.
- No socket present means one line saying the server is not running and how to start it.

## Testing

Following the existing conventions: `test_whatItDoes`, a real in-memory `DatabaseLayer`
in preference to mocks, `SampleTool` where a node type is needed but which one is not.

**Codec** (`SemelProtocol` tests) — round trip of every kind; truncation mid-header and
mid-body; zero-length JSON and body; a declared length over the limit rejected before
allocation; a wrong version byte; every `Request`, `Response` and `Event` case encodes and
decodes to an equal value.

**Handler** (`SemelServ` tests) — each daemon request against an in-memory database;
`pathNotFound` versus an empty listing; a batch left open at session teardown is closed;
the engine's reporters reach the event sink as events.

**Connections** — `InProcessConnection` in phase 2 and `SocketConnection` in phase 3:
interleaved sends from separate threads each receive their own reply; an event frame
reaches `onEvent` without disturbing a pending reply.

**Plugins** (`SemelCLI` tests) — against a fake `SemelConnection` that records requests and
returns canned responses. This gives the interpreter and plugins the coverage they have
never had, because testing them no longer needs an engine.

**End-to-end** (phase 3) — a handful over a loopback socket: hello, push, list, fetch,
and an event reaching a subscriber.

## Known consequences

- **Two processes to keep in step.** A protocol version bump means restarting the server.
  `Hello` makes the mismatch a clear message rather than a confusing one.
- **`debug` returns the whole graph as one string.** Fine at today's sizes; the 1 MB JSON
  limit is the first thing a very large graph will hit, and the fix then is a body rather
  than a JSON field.
- **The server's stdout is no longer the user's terminal.** Everything the engine used to
  print now goes through a reporter closure. Any `print` added to the engine after this
  is a bug: it will land in a log nobody reads.
