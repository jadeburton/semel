# `semel-cache`: a separate program, shared libraries, four phases

Status: design, for review before any code. Builds on
`2026-08-15-semel-cache-server-design.md` (status "design agreed"), whose decisions it keeps:
one shared cache that every engine reads from and writes to, two tiers (an action cache of
entries and an object store of bytes), the frame protocol, `cost` as the input to a fetch
policy, read-only by default, degradation to a miss on every remote failure. What this
document adds is decided on 2026-10-11: the server is its own program, what the two
programs share is factored into libraries, and the work lands in phases that each leave
the repository working.

## Decisions

- **A separate program, `semel-cache`.** Not a role of `semelserv`. `Hello`'s `Role`
  (`daemon`, `cache`, `runner`) stays, because it names what a peer *is* when two
  processes meet; it no longer names which binary runs it. The reason is the dependency
  graph: a cache server that lives inside `semelserv` links the engine, the toolchain
  plugins and the graph database, none of which it needs, which is the mistake AGENTS.md
  forbids a toolchain package to make towards the engine. The client side already works
  this way — five executables over `SemelCLI` and `SemelProtocol` — and the server side
  follows it. The one argument for a single binary, one thing to install, does not hold:
  the cache server runs on a different machine from the engines by design.
- **The rule, written into AGENTS.md:** `semel-cache` links `SemelCache`, `SemelTransport`,
  `SemelProtocol` and `SemelNodeKit`, and never `SemelCore`. A type both servers need lives
  in one of the shared libraries, never in either program. The runner (B-03, remote tool
  execution) will be a third program under the same rule when its time comes.
- **Two libraries come out of what exists.**
  - `SemelTransport` already exists in the root package (`semel/Transport/FrameStream`); it
    gains the listener side, generalised from a Unix socket to a TCP endpoint, and takes
    `SocketConnection` and `ServerConnection` (framing, correlation, streamed replies
    from B-137, pipelining from #163) out of `SemelCLI` and `SemelServer`, so one
    implementation of the wire serves every client and both servers.
  - `SemelCache`, new, out of `SemelCore`: `ProcessCacheEntry`, the key material and its
    hashing, the entry's `cost`, B-148's size accounting and eviction order. The engine
    links it for the local cache; the server links it for the shared one; one definition
    of an entry serves both, so a key computed by an engine is the key the server stores.
    The database rows the local cache keeps stay in `SemelCore` behind a `CacheStore`
    protocol that `SemelCache` declares and both the engine's SQLite and the server's
    store implement.
- **The protocol is the August table, as typed cases.** `CacheRequest` and `CacheResponse`
  enums in `SemelProtocol` beside `DaemonRequest` and `DaemonResponse`: `getEntry(key:)`,
  `putEntry(key:entry:cost:)`, `hasObjects(hashes:)` answering the missing ones,
  `getObject(hash:)` with the bytes in the frame body, `putObject(hash:)` with the bytes in
  the body and the hash verified on receipt. `Hello` carries `wantsWrite` and the server
  answers accepted, read-only or rejected. Nothing in a request is text to be parsed; a
  key is the `CacheKey` value `SemelCache` defines.
- **What the engine does, behind the two hooks that exist.** On a local miss,
  `loadCachedOutputs` asks the remote for the entry, then `hasObjects` for what the
  entry references, fetches the missing objects into the local store, and returns the
  entry as if it had been local; any failure on that path, the server unreachable, a
  missing object, a hash that does not verify, is a miss. After a local write,
  `saveCacheForAllInputsAndOutputs` hands the entry and its objects to a population queue
  that runs off the processing path: remote writes never block a build, and a slow or
  dead server makes builds slower, never incorrect and never stuck. The fetch policy
  compares the entry's recorded `cost` with an estimate of the fetch (bytes missing over
  the link's measured rate) and recomputes when fetching would lose; on a LAN in the
  first version the estimate is a constant and every hit is taken.
- **Time, named.** The server's eviction is by B-148's order: entries a node holds are not
  evicted (the server has no nodes; it keeps what the last N clients used, counted in
  requests rather than settles), then lowest `cost` per byte first. `cost` is a duration
  and AGENTS.md's time-free invariant already names the cache's eviction as an accepted
  exception; the server's clock enters nowhere else. No entry carries a timestamp.
- **Trust, as the August spec decided.** Read-only by default; `wantsWrite` is granted by
  the server's configuration to named client identities, the usual deployment being that
  CI writes and developers read. `Hello`'s identity is asserted, not authenticated, over a
  LAN or VPN; the field is there so authentication is not a protocol change. A poisoned
  entry is sticky until evicted or purged, so `semel-cache purge <key>` and `purge --all`
  exist from the first version.
- **The correctness prerequisite is largely met and the rest is listed.** The August
  spec's live example, the SDK not in the Swift tools' key, is closed: B-47 fingerprints
  the SDK in every tool that reads it and writes it into the machine file; every tool's
  binary is fingerprinted; B-80 fingerprints the compiler's plugin trees; the sandbox
  scrubs the environment and the hermeticity builds perturb locale, time zone and the
  mount. What remains is audited in phase 3 before sharing is switched on: anything a tool
  can observe that no key names, with the machine-file lines as the place a new machine
  fact goes.

## Phases

1. **Extraction, no behaviour change.** `SemelTransport` takes the connection classes and
   gains a TCP listener and connection; `SemelCache` takes the entry, key material and
   B-148's accounting out of `SemelCore` behind `CacheStore`; the engine's SQLite store
   implements it; every suite passes unchanged; `ProtocolVersion` unchanged. The rule
   goes into AGENTS.md. This is a refactor and its test is that nothing moved on the
   wire or in the database.
2. **The server.** `semel-cache` with `CacheRequest`/`CacheResponse`, a store on disk
   under its own home (an object store the node kit already provides and an index in
   SQLite through `CacheStore`), `Hello` with `wantsWrite` and the configured writers,
   B-148's limit and eviction, `purge`, and `semel-cache status` printing entries, bytes,
   hits and misses since start. Tested against an in-memory store with no socket, then
   over a real TCP socket on localhost.
3. **The engine as a client.** `semel.engine.config` in the home names the server
   (`cache.server`, `cache.identity`), never the machine file; the two hooks gain the
   remote path with the population queue and the fetch policy; the machine-derived-input
   audit; `cache` at the
   prompt shows the remote's hits, misses, bytes fetched and the queue's depth beside the
   local figures. Degradation tests with the server stopped mid-build.
4. **The acceptance test.** Two homes on one Mac with `semel-cache` on localhost: home A
   builds a roster project cold and populates; home B, cold, builds the same project and
   produces byte-identical products with every tool node a remote hit; then the same with
   the server stopped halfway. In CI as a fixture run; the roster projects locally. Then
   sharing is on by default when a server is named.

## Testing

- Phase 1: every existing suite, unchanged; a test that the entry's encoding is the same
  bytes before and after the move (a pinned fixture of an entry).
- Phase 2: the protocol handlers over an in-memory store; the hash verified on
  `putObject`; a hit whose objects are missing is a miss; read-only clients refused on
  write; eviction at the limit; `purge`; the TCP listener with two clients at once.
- Phase 3: the remote path behind each hook with a fake remote; a failure at each step
  degrades to a miss; the population queue never blocks a settle; the fetch policy's
  decision for a cheap entry over a slow link.
- Phase 4: the two-home acceptance run, byte for byte.

## Settings

Fewer than the word suggests, and none of them inside the graph.

- **The rule.** A setting that must not affect a build never enters `input:` and never
  enters a key. The machine file (`semel.machine.config`) is pushed into `input:` and read
  by nodes through config filters, so it is exactly the wrong place for the cache's
  address; the same goes for `semel.config`. The cache settings live in a file in the
  Semel home beside `semel.base` — `semel.engine.config`, in the `key value` form the
  home's other files use — read by `semelserv` when it starts and rewritten by the prompt.
  B-148's `cache limit`, which stores its value in the graph database today, moves to this
  file in phase 1 so that the home has one place for the engine's own settings.
- **The engine's side**, in `semel.engine.config`: `cache.server` (host and port),
  `cache.identity` (the name this client gives in `Hello`), `cache.limit` (B-148's). With
  no `cache.server` line the engine uses its local cache alone, which is today's
  behaviour. At the prompt, `cache server <host:port>`, `cache identity <name>` and
  `cache limit <size>` write the file and apply at once through a request to the running
  server; `cache` prints them with the figures. Nothing else in the first version; an
  estimate of the link's rate for the fetch policy becomes a setting only if a LAN turns
  out not to be the only case.
- **The server's side**, as arguments and a file in its own home: the home folder, the
  address and port it listens on, the size limit (B-148's), and who may write.

## Decided on review (2026-10-11)

- **The server's store is the cache-related subset of the engine's database.** The entry
  index and B-148's size accounting, as `SemelCache` defines them, in SQLite, beside the
  node kit's object store on disk. The engine's database is that subset plus the graph
  tables: one schema and one `CacheStore` implementation, two databases that differ only
  in what else they hold.
- **Writers, first version: a switch.** Anyone who can write to a shared cache can poison
  every reader, so a client says `wantsWrite` in `Hello` and the server decides. The
  first deployment is everyone trusted, so the server takes `--writers all` or
  `--writers none`; a list of identities comes when a deployment needs one, as a change
  to the server's configuration and not to the protocol.
- The engine-side namespace is `cache.*`.

## As built (phase 2, 2026-10-12)

Where the server differs from the text above, and what this document left open that phase
2 had to decide.

- **The server never parses an entry** (an owner decision during phase 2). `putEntry`
  carries the key, the recorded cost, the hashes of every object the entry references and
  the body's length as typed fields, and the entry as opaque bytes in the frame body — the
  engine's encoding, stored as it came; `getEntry` answers `entry(cost:)` with those bytes
  in the body, and the engine decodes them. The server reads nothing inside an entry: its
  accounting, eviction and `hasObjects` run on the fields, and the one check on an entry's
  bytes is its length. So the table's `putEntry(key:entry:cost:)` is
  `putEntry(key:cost:objects:length:)` with the entry in the body, and the server links
  `SemelCache` for `CacheKey`, the accounting and the eviction order, never for
  `ProcessCacheEntry`'s decoding. The entry's format is the engine's business; the server is
  a byte store with an index, which is also what makes it fast. The body also lifts the
  JSON section's 1 MiB cap off an entry, which a product builder's spec table can pass.
- **Answering quickly, with durability traded for it and never consistency** (an owner
  requirement). The index is in memory — every key, object hash and size — kept in step
  with the disk, so a miss and `hasObjects` never touch it; the in-memory index is a
  `CacheStore`, so `SemelCache`'s one trim runs over it without a query. The disk is the
  cache's tables in SQLite (`CacheIndexDatabase`: WAL, `synchronous=NORMAL`, never `OFF`,
  which can corrupt after a power failure; a large page cache and `mmap_size`; SQLite's
  checkpoint on commit off) and the node kit's object store. Writes are queued and one
  writer thread commits them in batches, each one transaction; a `putEntry` is answered
  once its batch is in the write-ahead log, and a connection's next request is prepared
  meanwhile, so one client's entries share batches. A `putObject` is answered once its bytes
  are hashed and in memory, and its file is written behind the answer. The log is
  checkpointed when the writer is idle. A crash can lose the last batches and objects and
  leaves the store consistent: on opening, an entry whose objects did not survive is dropped
  and an object no entry holds is removed. Measured on an Apple M4 over TCP on localhost
  with a warm index (release server, debug client, medians of two runs): `getEntry` hit
  161–236 µs and miss 130–178 µs, `hasObjects` for 100 hashes 232–307 µs, `getObject` of
  1 MB 1.1–1.3 ms, `putObject` of 1 MB 1.4–1.8 ms; one client putting 1,000 entries with
  10,000 objects of 4 KB, pipelined, in 1.5–2.1 s (5,300–7,500 requests/s), against a
  ceiling of 6,800–9,300 pipelined misses a second on one connection.
- **The store's queries moved below the engine, the schema did not.** `SQLiteCacheStore` is
  `SemelCache`'s, over `CacheDatabase` (the engine's `DatabaseLayer` conforms); the cache's
  tables are still created by `CacheEntry.createTable` in the database models, which the
  graph's database and a server's index both call — one schema, two databases. What joins
  the graph stays in `SemelCore`.
- **Uses counted in requests.** Every 10,000 entry requests (`getEntry`, `putEntry`) close a
  use; what the last one or two windows touched is kept over everything else, then the
  cheapest build per byte goes first. A put that takes the store over its limit trims it to
  nine tenths of the limit, so a store at its limit does not trim on every put. The server
  knows no entry's node type, so its entries' `nodeType` is empty.
- **`status` and `purge` go through the running server.** The index in memory is the one
  place a running store changes, so with the home's lock held both connect to the address
  `semel.cache.config` names; with it free they open the home themselves. A purge asks for
  write access and nothing more — a writer could overwrite any entry anyway — so a server
  run with `--writers none` is purged by stopping it and purging its home. Hits and misses
  are a running server's, since it started; a stopped home reports entries and bytes.
- **Hello.** `wantsWrite` reads as false when absent, so an older peer is told its version
  differs rather than that its hello was malformed. A cache's acceptance is a case of its
  own, `cacheAccepted(access:)` with `readWrite` or `readOnly`, beside the daemon's
  `accepted(serverVersion:databasePath:)`. No request is answered before an accepted hello.
- **Hashes are checked before they name a path**: lowercase hex, two digits to a byte, at
  most a SHA-256's worth (an object no longer than a digest is filed under its own bytes),
  so nothing a client sends names a file outside the store.
- **Open.** An object put for an entry that never comes stays until the store next opens or
  `purge --all`. An object over the frame body's 512 MiB cannot be shared. `Hello` carries
  no identity yet; it comes with phase 3's `cache.identity`.

## As built (phase 3, 2026-10-12)

Where the engine's side differs from the text above, what the text left open that phase 3
decided, and the audit it owed.

- **Where the client lives.** The brief put a `RemoteCache` client in `SemelCache`, linking
  `SemelTransport` for the TCP connection. That is a cycle: `SemelProtocol` links
  `SemelCache` for `CacheKey`, and the transport links the protocol. So `SemelCache` declares
  what it needs of a remote — the `RemoteCache` protocol, a blocking call per request, each
  failure a `RemoteCacheError` case that says whether the connection is gone — and holds
  everything an engine does with one in `SharedCache`: the fetch on a local miss, the
  population queue and its thread, the reconnection, the fetch policy (`CacheFetchPolicy`)
  and the figures. The one conformance that speaks frames, `SocketRemoteCache`, is a target
  of the root package, `SemelCacheClient`, above the cache, the protocol and the transport;
  `SemelServer` links it and installs a `SharedCache` over it into the engine from the
  home's settings. The engine links neither the transport nor the protocol, and the tests of
  the hooks run over a remote in the test's process: a `CacheStore` and an object store
  behind the protocol.
- **Settings.** `cache.server` is a `CacheAddress` — the host-and-port type `semel-cache
  --listen` already parsed, moved into `SemelProtocol` so that one parser reads both ends'
  files — and `cache.identity` one word. `cache server <host:port>|--none` and `cache identity
  <name>|--none` write `semel.engine.config` first and then put a new `SharedCache` in force,
  stopping the one before without writing its queue (its entries were meant for a server
  the home no longer names); a new identity connects again, since the name is said in the
  hello. `semelserv` reads both at start. With no server named, no `SharedCache` exists
  and nothing on either hook changes.
- **The protocol, version 30.** `Hello` gains `identity`, absent when the home names none
  (and decoded as none from a peer that never sent one); the server keeps it with the
  connection's grant for the writers' list a deployment will name, and `--writers all|none`
  decides without it. `getEntry`'s hit is `entry(cost:objects:)`: every object the entry holds
  with its size, from the server's index, so the client knows what a fetch would move before
  it moves anything — the server stored the list when the entry was put, and reads nothing
  inside the entry to give it. The engine's requests `cacheServer(address:)` and
  `cacheIdentity(identity:)` answer `sharedCache(summary:)`, and `cache`'s summary carries
  the same `SharedCacheSummary`. Version 29 was taken by the monitor's phase 3 meanwhile.
- **The lookup** follows the design: `getEntry`; the entry decoded and its own material's
  key compared with the key asked — the server files what a client says under what the
  client says, and an entry filed under a key it does not account for is the wrong hit
  B-13 exists to prevent; `hasObjects` for the objects this machine lacks, before a byte
  moves; the policy; `getObject` for each, hashed before it is stored; then the entry into
  the local cache with the server's object list, stamped as used, and applied as a hit.
  Each failure is a miss, counted, its words kept for `cache`, and the connection marked
  down when the failure ended it — only the connection the call was made on, so a late
  failure on a replaced connection does not take down its successor. A type with no static
  input port never writes an entry, so it never asks.
- **The population queue** holds a thousand entries or 64 MiB of them and drops its oldest
  past either; an item is the key, the cost, the objects with their sizes and the entry's
  bytes — the objects' bytes are read from the object store when it is written. A read-only
  grant empties the queue and takes nothing more. `populate` takes the lock for an append
  and returns: a settle whose server takes no write completes (`SharedCacheTests`, with
  every put held until the test lets go).
- **The fetch policy.** The text had one rate; the first acceptance run showed why that
  fails. A rate taken over every fetch read a localhost link as about 4 MB/s, because an
  object of a few kilobytes costs a round trip whatever the bandwidth, and the policy
  declined fifteen of the C fixture's tool builds. The estimate is now two figures: a
  request's own cost, the quickest of the last 32 fetches, per object fetched; and the bytes
  over the rate the fetches of 64 KiB or more moved at once that cost is taken off them. The
  rate is 100 MB/s until such a fetch has been measured — a gigabit Ethernet's payload
  rounded down, the slowest wired link of the first deployment (a LAN), at which a megabyte
  costs 10 ms, under nearly any tool's run. On the second run nothing was declined. A hit
  whose objects are all here already is always taken; a cost of 0 ms with anything to fetch
  never is, which declines the engine's own cheap nodes, as it should.
- **Reconnection.** The queue's thread connects, and connects again with the watcher's
  backoff, 0.25 s doubling to 5 s, when a lookup or a write finds the connection gone; a
  rejected hello is asked again at the longest wait. A lookup while the connection is down
  is a flag read under the lock. `SocketRemoteCache` closes a connection whose request has
  had 15 s and a second per megabyte it carries without an answer, which fails every call
  on it, so a server that stops answering without closing costs one bounded wait.
- **Time** enters only `SharedCache`, which is resource policy: the fetch policy times
  fetches, and the reconnection waits. Both decide whether a build is fetched or run, never
  what it computes. AGENTS.md's time-free invariant says so.

### The audit of machine-derived inputs

Every node that runs a binary, walked from `cacheKeyMaterial` to what `LocalFileSystemTool`
hands the tool. What every one shares: the environment is replaced, not inherited — `PATH`
is `/usr/bin:/bin:/usr/sbin:/sbin`, `HOME` and `TMPDIR` are the sandbox, and a node adds
only `ZERO_AR_DATE` (the archivers), `IBToolNeverDeque` (actool, ibtool) or
`CODESIGN_ALLOCATE` (codesign) — so `DEVELOPER_DIR`, `SDKROOT`, `LANG` and `TZ` never reach a
tool; the arguments derive from the node's properties, its input values and its
configuration, which arrives on a wire and is in the key; the binary named is fingerprinted
by its bytes (B-17); every SDK fact is in the key and in the machine file (B-47); swiftc's
plugins are fingerprinted (B-80).

| Node | Version | Key, beside properties and wires | Found | Now |
|---|---|---|---|---|
| ClangPreprocessor | 12 | `sdkPath`, `sdkFingerprint` lines; the SDK's live fingerprint; clang's bytes | `ld` not covered (shared finder) | `ld` in clang's fingerprint |
| ClangCompiler | 7 | as above; module cache in the sandbox | as above | as above |
| ClangLinker | 5 | as above; `-L <sdk>/usr/lib` | the linker `ld` clang runs is not in the key | `ld` in clang's fingerprint |
| ClangArchiver | 3 | libtool's bytes; `ZERO_AR_DATE` | none; reads no SDK | — |
| LexGenerator | 1 | lex's bytes | flex runs `m4` through the `/usr/bin` shim | `DEVELOPER_DIR` set; `flex`, `m4`, `gm4`, `bm4` in lex's fingerprint (B-157) |
| SwiftCompiler | 9 | SDK name and fingerprint; swiftc's bytes and plugins | `swift-driver` not covered; module cache outside the sandbox | driver, clang, `ld`, libtool in swiftc's fingerprint; cache open, B-157 |
| SwiftLinker | 6 | as above | clang, `ld`, libtool not covered | in swiftc's fingerprint |
| SwiftPackageReader | 3 | swift's bytes | `swift-package` not covered; the manifest's SDK found through `xcrun` | `swift-package` in swift's fingerprint; `DEVELOPER_DIR` set, no manifest cache, version 5 (B-157) |
| AssetCatalogCompiler | 6 → 7 | actool's bytes; `assetutilPath` | compiles through the system's CoreUI and, for iOS, the simulator runtime's frameworks | system build; iOS runtimes |
| IBToolCompiler | 5 → 6 | ibtool's bytes; SDK fingerprint | archives through AppKit, and UIKit of the runtime for iOS | system build; iOS runtimes |
| CoreDataModelCompiler | 1 → 2 | momc's bytes; SDK fingerprint | archives through the system's Core Data | system build |
| StringCatalogCompiler | 3 → 4 | xcstringstool's bytes | reads and writes through the system's Foundation | system build |
| CodeSigner | 6 → 7 | codesign's bytes; `codesignAllocatePath` as a path | signs through the Security framework; `codesign_allocate` by path only | system build; the allocator's bytes |

What was closed, each with a test: the system's build (`kern.osversion`, read with `sysctl`,
no process) in the keys of the five tools that work through the system's frameworks, and
the simulator runtimes installed for the platform (`xcrun simctl list runtimes`, asked once
per process) in actool's and ibtool's for a platform other than the Mac's — each declared
twice, as `hostOSBuild` and `simulatorRuntimes` lines under the namespaces `semel-swift
prepare` writes, with the five nodes' versions bumped; the binaries a tool runs from beside
itself in its descriptor's fingerprint (`siblingBinariesFingerprint`): `ld` beside clang,
`swift-driver`, clang, `ld` and libtool beside swiftc, `swift-package` beside swift, which
moves those keys without a bump; and `codesign_allocate`'s bytes in the signer's key, where
its path was. A macOS update now misses on every entry of those five tools, which is the
price of the system's frameworks being in their output.

What is left is filed as B-157, none of it a wrong hit between two machines:
`DEVELOPER_DIR` does not reach a tool, so a `/usr/bin` shim a tool runs follows
`xcode-select`; swiftc's implicit module cache is outside the sandbox (it validates itself,
so no output differs); the toolchain's trees beside the binaries are named by the tools'
versions, as the SDK class of gap; and three things cost sharing without making it wrong —
absolute tool and SDK paths in the clang and Apple configurations, the SDK and plugin
fingerprints taken of paths, sizes and times, and swiftc's plugin fingerprint covering
every installed platform. Measured between two real machines, those decide how much a
shared cache shares; on one Mac they cannot be seen.

The first was closed on 2026-10-12 (B-157 item 1): every tool runs with `DEVELOPER_DIR`
naming the developer folder discovery found, which enters no key — lex's fingerprint
carries the `flex` and `m4` it runs instead. The rows above say so.

## As built (phase 4, 2026-10-12)

The acceptance test is `SharedCacheEndToEndTests`, a fixture run in CI. `semel-cache serve`
on localhost with `--writers all`, and three homes that name it in `semel.engine.config` as
three machines would. Measured on an Apple M4 with debug builds, each time a `semel`
session from launch to exit, so a home's start and the export are in it (the C++ fixture
is the smaller build of the two):

- **A** builds the C fixture (3.7 s) and the C++ fixture (2.1 s) cold; its queue writes 61
  entries, none dropped or failed.
- **B**, cold, builds the C fixture in 2.4 s: 31 lookups, 31 hits — 11 ClangPreprocessor,
  6 ClangCompiler, 4 ClangLinker, 5 ClangIncludeFinder, 5 ProjectBuilder — none missed,
  failed or declined; the export is A's byte for byte.
- **C** builds the C fixture from the shared cache (31 hits), the server is stopped, and C
  builds the C++ fixture on its own: one failed lookup, which marked the connection down,
  29 lookups asked of nothing, 30 entries waiting in a queue that would drop past a
  thousand, and both exports A's byte for byte.

The server is stopped between two builds of one home rather than in the middle of a
settle, which a fixture this small finishes before a test can act; the stop in the middle
of a build is `SharedCacheTests`' (a remote that stops answering after a hit), and the
settle that completes while the queue's server takes nothing is too. The roster's external
projects have not been built between two homes. Sharing is on whenever a home names a
server; there is no switch beyond the setting.
