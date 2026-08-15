# Splitting Semel into `semelserv` and `semel`

**Status:** superseded pending decision — see
`2026-08-15-semel-cache-server-design.md`, which is the recommended direction
**Date:** 2026-08-15

> **Why this is on hold.** A shared *cache* server achieves the cross-user reuse this
> design was built for, at roughly a tenth of the complexity, while scaling with headcount
> rather than with one machine's cores and degrading to "slower" rather than "stopped"
> when the server is down. It also removes the artifact-subscription and file-watching
> subsystems entirely, because a locally-built artifact is already where you want it.
>
> This document is kept rather than deleted: the frame design is reused verbatim by the
> cache server, the push-protocol reasoning (blobs outside the transaction, manifest
> retained server-side, merge semantics and the measurements behind them) still applies,
> and the analysis of what a shared graph costs is the argument for not building it.

## What this is

Semel is one process today: a REPL that owns the build engine, the graph database and
the object store, and whose command plugins walk the node graph directly. This splits it
into a long-running server that owns all of that, and a client that reaches it over a
socket.

`FUTURE.md` already lists "convert to client-server architecture and daemon" and
"clearly delineate Core, DatabaseModels, CLI, SemelServ". This is that work.

## Goals

- One `semelserv` process owns the engine, the graph and the store.
- N `semel` clients talk to it concurrently over a long-lived socket.
- All users share **one** graph, with a per-user home directory off the root of both the
  input and output file systems. Sharing is deliberate: the content-addressed store means
  a file one person pushes is instantly free for everyone else.
- `SemelCore` comes out of this unchanged, and in particular learns nothing about
  users, sockets or sessions. That is the test of whether the seam is in the right place.

## Non-goals for this round

Named explicitly because each was discussed and deliberately cut:

- **Authentication.** The client asserts a username and an admin flag; the server trusts
  it. The protocol has the field so adding real auth later is not a breaking change.
  Until then, run on a LAN or VPN.
- **Server-initiated messages.** The frame reserves a message kind for them and nothing
  sends one. Artifact-change subscriptions come later.
- **File watching and automatic artifact delivery.** The eventual shape — edit locally,
  changes coalesce behind a Nagle-style timer, artifacts appear in a chosen directory —
  informs the frame design and nothing else here.
- **Reconciliation.** No full-tree comparison, on connect or otherwise. The user decides
  what to push, as they do today.
- **Server-side wildcard expansion.** Clients expand globs by listing.
- **Blob garbage collection.** See "Known consequences".

## Scale

Up to ~100 users on a local network or VPN. Not a stateless high-volume service. This is
why per-connection server state is acceptable, and why several designs that would be
necessary at larger scale are deliberately not here.

## Module layout

```
SemelCore      unchanged — no users, no sockets, no sessions
SemelDatabaseModels       unchanged
SemelProtocol   NEW  frame codec + message types; shared by client and server
semelserv       NEW  owns BuildEngine + DatabaseLayer + DataObjectStore;
                     listener, per-connection state, path authorisation
SemelCLI       keeps CommandInterpreter and plugins; CommandContext now
                     holds a SemelClient instead of DatabaseLayer/BuildEngine
semel                REPL, command parsing, session state, local disk I/O
```

The process-global singletons (`DatabaseLayer.shared`, `BuildEngine.shared`,
`DataObjectStore.shared`, `ToolExecutorRegistry.instance`) become an asset rather than a
liability here: one engine, one graph, one store, resolved once in `semelserv`'s
composition root. That is the shape they were always suited to.

## Transport

`Network.framework`, which provides `NWProtocolWebSocket` if WebSocket framing is wanted
later — so remote operation costs no third-party dependency, at the price of pinning
`semelserv` to Apple platforms. That matches the existing `.macOS(.v13)` floor.

The frame below is transport-agnostic: it sits unchanged on a TCP stream, a Unix socket,
or inside WebSocket binary messages.

## The frame

Every frame carries an optional JSON section and an optional binary body. All integers
big-endian.

```
offset  size  field
─────────────────────────────────────────────
  0      1    version         1
  1      1    kind            1=request 2=response 3=event
  2      1    flags           reserved (chunking, compression)
  3      1    reserved
  4      8    correlationID   UInt64, echoed in the response
 12      4    jsonLength      UInt32
 16      8    bodyLength      UInt64
 24      …    json bytes      PolyFactory-tagged, may be empty
  …      …    body bytes      raw, may be empty
```

**Both sections in one frame.** `StoreFile` is metadata plus bytes; `GetContent`'s reply
is metadata plus bytes. If a frame were *either* JSON *or* binary, those would need two
frames tied by correlation ID, with the failure mode of one arriving without the other.
One frame per operation per direction also keeps blobs out of JSON — no base64, no 33%
inflation on a multi-megabyte artifact.

**No magic bytes.** TCP already gives ordered, integrity-checked delivery. A desync would
be our own framing bug, which a magic number would report only after the fact.

**The message type is not in the header.** It is the PolyFactory `kind` inside the JSON.
`PolyFactory` already maps `kind` → Codable type and is already hardened against
untrusted input. A second discriminator in the header would be two sources of truth for
one question.

**`kind` reserves server→client events.** Nothing sends one in this round. The byte exists
so that artifact-change notifications are a new PolyFactory type later, not a new framing.

**`correlationID` allows several requests in flight.** A REPL typing one command at a time
does not need it; a file watcher pushing while the user runs `ls` does, and retrofitting
it breaks every client.

**Extension points** are `version` and `flags`. Known limit: a body is one frame, so a
7 MB artifact is read whole into memory per client. Acceptable at this scale; a flags bit
for chunked bodies is the escape hatch, deliberately not built.

## Messages

Each is a PolyFactory-registered Codable type. `→` marks a binary body.

| Request | Payload | Response |
|---|---|---|
| `Hello` | username, isAdmin, protocolVersion | accepted / rejected + reason |
| `ListDirectory` | path | entries: name, isFolder, isPinned, hash?, size |
| `GetContent` | hash | → bytes |
| `StoreFile` | hash → bytes | stored |
| `AddFiles` | [(path, hash)] | status: `applied` \| `awaitingHashes`, unknownHashes[] |
| `RetryBatch` | batchID | same shape as `AddFiles` |
| `Delete` | path | deleted |
| `GetErrors` | pathPrefix? | [(node, port, message)] |
| `GetActiveTasks` | — | [(node, description)] |
| `Debug` | — | giant string *(admin)* |
| `Reset` | — | ok *(admin)* |

`ListDirectory` is single-level, matching `FolderManifest` — which is by design "a
non-recursive list of immediate children" — and is what drives the existing wildcard
matcher one level at a time. A path that does not exist is `pathNotFound`, not an empty
listing, so a client can tell "no such directory" from "directory with nothing in it".

**Two version fields, deliberately.** The frame's `version` byte governs *framing* and is
checked before anything is decoded; a mismatch closes the connection because nothing
further can be trusted. `Hello.protocolVersion` governs the *message set* and is
negotiated once framing is known to work, so a mismatch can be reported as a clean
rejection with a reason.

**`AddFiles` creates intermediate folders** along each path, as `push` does today via
`ensureEntirePathExistsAsFolders`. It cannot create one whose name collides with an
existing file — that surfaces as the `nameCollision` the node layer already enforces.

**`Delete` on a folder is recursive**, matching today's `rm`. Deleting something that does
not exist is `pathNotFound` rather than silent success, so a client that thinks it is
tracking the tree finds out when it is wrong.

`isPinned` is exposed because the engine's "ghost" entries (referenced but deleted) are
visible in `ls` today, and hiding them would be a behaviour change.

`GetErrors` takes an optional path prefix so a user sees their own tree rather than
everyone's.

`nudge` is deliberately not exposed. `debug` returns the whole graph as one string and is
admin-only for that reason.

## The push protocol

Merge semantics: `AddFiles` merges the listed paths into their folders. Absence does not
imply deletion — removal goes through `Delete`. The user decides what to push, typically
a folder rather than a whole tree.

```
AddFiles(manifest)   all hashes known    → applied in one transaction
                     some unknown        → unknownHashes[], manifest retained
StoreFile × K                            → stored
RetryBatch(batchID)                      → re-attempts the retained manifest
```

**Blobs are never part of the transaction.** Storing a blob has no graph effect — it puts
content in a content-addressed store, idempotently. Only `AddFiles` mutates the graph.
So `StoreFile` is applied eagerly, in any order, with no batch context, and the object
store needs no knowledge that batches exist. Keeping the store ignorant of the
file/directory layer is the point; an earlier design had the store auto-commit a batch on
receiving its last blob, which worked but mixed the two concerns.

**`AddFiles` is all-or-nothing.** If any hash is missing the server applies *nothing*. A
partially applied tree is one the engine immediately starts compiling, producing errors
other users then see.

**The manifest is sent once.** It is retained server-side, keyed by the `AddFiles`
correlationID, so the retry is a few bytes rather than a resend.

**Batches are keyed, not implicit.** "Retry the last batch" becomes ambiguous the moment a
watcher has two pushes in flight on one connection.

**`StoreFile` carries the client's hash and the server verifies it.** The server could
hash the bytes itself, but the client already computed it to build the manifest. Sending
it turns silent corruption into a loud mismatch for 64 bytes.

**Unknown hashes are a normal response, not an error.** A partial push is the expected
handshake. Making it an error type forces every client to special-case one error as
control flow, and buries genuine failures in logs full of them.

### Why this shape, quantitatively

Measured on the tree currently pushed (324 files, 10.8 MB, average path 71 characters), a
manifest entry is ~155 bytes, so a full-tree manifest is ~50 KB.

Hit rates are bimodal — essentially never an average:

| Case | Server already has | Frequency |
|---|---|---|
| First push of a new project | ~0% | once |
| A user pushing what a colleague already pushed | ~100% | once per person |
| **Incremental save** | **~99.7%** | **constant** |
| Branch switch / pull | ~95%, or ~100% if those revisions were ever pushed | occasional |

For a one-file save, the changed blob is ~4 KB and a full-tree manifest would be ~50 KB —
**the manifest is 12× the payload**, and at 20,000 files it is ~3 MB per save. Blob
transfer was already near-optimal; the manifest was not. Merge semantics is what makes
the manifest proportional to what changed.

This is why `HaveHashes` — a pure "which of these do you have?" query — was designed and
then dropped. Under merge semantics you are asking about three hashes, not three hundred,
so it earns nothing.

## Server internals

**Concurrency needs no new machinery.** N connections and the engine's `processLoop` all
mutate one database; GRDB's `dbQueue` already serialises writes and `withTransaction`
already handles nesting via its task-local. This is not new — today the REPL thread and
the engine's background `Task` race the same way, and the queue is what makes it safe. An
`AddFiles` transaction and the engine's phase-2 apply will briefly block each other, which
is fine at this scale.

**One actor per connection**, holding username, admin flag, and pending batches keyed by
correlationID. Torn down on disconnect, which discards abandoned batches for free. A
timeout covers a batch whose blobs never arrive.

**Path authorisation lives in `semelserv`.** Every path-bearing message is checked against
`input:/<user>/…` or `output:/<user>/…` unless the connection is admin.

**The server normalises paths itself and does not trust the client's normalisation.**
`CommandContext.resolve` handles `..` client-side today and it would be natural to assume
arriving paths are clean. They are not: `input:/jade/../bob/secrets` is an ordinary string
to put on a socket. Normalise, then check the prefix, then act. With auth deferred this is
porous anyway, but building the check correctly now is what makes enabling auth later
actually secure something.

**Where the current plugin logic goes:**

```
NavigationPlugin  ls → ListDirectory;  cd/pwd → client only
FilePlugin        push → client-side glob over local disk, StoreFile, AddFiles
                  rm   → client-side glob via RemoteFileSystemLister, Delete
                  cp   → GetContent + local write; fileMetadata drives chmod
EnginePlugin      debug / errors / reset → server; debug and reset admin-only
SessionPlugin     entirely client-side
```

`FileWildcardMatcher` already abstracts over `FileWildcardMatcherInput`, with
`ExternalFileSystemLister` (local disk) and `InternalFileSystemLister` (graph). A third
implementation, `RemoteFileSystemLister` backed by `ListDirectory`, makes every existing
glob path work client-side with no new protocol messages and no change to the matcher.

## Error handling

Five layers, deliberately not collapsed:

**Frame** — malformed header, implausible lengths, unsupported frame `version`. Framing
being broken means `correlationID` cannot be trusted enough to reply, so close the
connection. A *message-set* version mismatch is a different thing and is rejected cleanly
in `Hello`, where framing is already known to work.

`jsonLength` is `UInt32` and `bodyLength` is `UInt64`, so a buggy or hostile client can
ask the server to allocate absurd amounts before sending a byte. Both need caps —
suggested 1 MB for JSON and a configurable ceiling (512 MB) for bodies — enforced *before*
allocation.

**Message** — unknown PolyFactory kind, undecodable JSON. `ErrorResponse` carrying the
correlationID; the connection survives.

**Semantic** — `ErrorResponse` with enough context to act on, per the house rule that an
error which only says something failed is not finished:

```swift
case pathNotFound(path: String)
case pathOutsideHome(path: String, home: String)
case notPermitted(operation: String, requiresAdmin: Bool)
case unknownHash(hash: String)
case hashMismatch(declared: String, computed: String)
case noSuchBatch(batchID: UInt64)
case nameCollision(path: String, existingIsFolder: Bool)
case frameTooLarge(field: String, limit: UInt64, actual: UInt64)
```

Note that `unknownHash` is for `GetContent` asking for a blob the server does not hold. It
is *not* how `AddFiles` reports missing hashes — that is a normal response, for the reason
given above.

**Build errors are data, not protocol errors.** A node that fails to compile comes back
from `GetErrors`. This mirrors the existing distinction between a node failure and an
`UnrecoverableError`.

**`UnrecoverableError` is the exception.** "A store that cannot be written belongs to the
machine." It is not attributable to whichever client happened to trigger it; the server
surfaces it prominently and stops accepting mutations rather than reporting it to one
unlucky connection.

## Testing

Four layers, following the existing conventions (`SemelCoreTestCase`,
`test_whatItDoes`, a real in-memory `DatabaseLayer` in preference to mocks).

**Frame codec** — round-trip, truncation mid-header and mid-body, zero-length sections,
oversized declared lengths. Pure and fast.

**Message handlers** — driven directly against a real in-memory `DatabaseLayer`, no socket.
Path normalisation and escape attempts (`input:/jade/../bob`), `AddFiles` applying nothing
when a hash is missing, `RetryBatch` completing a retained manifest, admin-only gating.

**Client plugins against a fake `SemelClient`** — the 753 lines of `CommandInterpreter` and
plugins have almost no coverage today because testing them requires a whole engine. Once
`CommandContext` hands out a protocol instead of a live `DatabaseLayer` and `Node`, faking
it is trivial. This is the quiet win of the split.

**End-to-end** — a handful over a loopback socket: connect, push, list, fetch back.

Specifically wanted: `RemoteFileSystemLister` tested against the same expectations as
`InternalFileSystemLister`, so wildcard behaviour cannot quietly diverge between client
and server.

## Known consequences

- **Unreferenced blobs accumulate.** A batch abandoned mid-flight leaves its stored blobs
  behind. They are content-addressed and harmless, but there is no blob GC today. Named
  here so it is not discovered as disk pressure later.
- **`reset` invalidates every user's cache.** It preserves all input files, so nobody
  loses work, but on a shared server one person's reset forces a full rebuild for
  everyone. A subtree-scoped reset is the natural multi-user form and does not exist.
- **Client and server can disagree about the tree**, since there is no reconciliation. The
  onus is on the user to push what they edited.

## The shape of the next round

This is a filesystem-synchronisation problem more than a git-style-push problem, and the
next iteration should start from that rather than rediscover it. In order:

1. **Artifact subscription** — client registers interest in a subtree of `output:`, server
   pushes change notifications (path, hash), client fetches and mirrors locally. Needs the
   `event` frame kind that is already reserved.
2. **Working copy** — file watching, Nagle-style coalescing, a local directory paired with
   a remote path prefix. The coalescing timer's expiry is a natural batch boundary, which
   is what the manifest already models.
3. **Reconciliation** — cheaply, via a per-folder content hash so a client can skip
   matching subtrees. Note this does not exist today: `FolderManifestEntry` is
   `name`/`isFolder`/`isPinned` with no content hash, so the current folder manifest
   changes only when names change, not contents. It would need a derived hash over the
   sorted (name, contentHash) pairs.
4. **Authentication**, and with it a real privilege model rather than an asserted flag.

Separately, and noted because it fits this architecture unusually well: **only publishing
artifacts from a build that passed.** Test, lint and analysis steps are ordinary nodes, so
they cache and re-run only when their transitive inputs change. Because the store is
append-only and a tree state is just a set of (path, hash) pairs, "the last good state" is
a pointer rather than a snapshot. Pinning what `output:` publishes to the newest passing
state — rather than rolling `input:` back — gives the useful guarantee without fighting
the file watcher, which would otherwise immediately re-push the reverted file.
