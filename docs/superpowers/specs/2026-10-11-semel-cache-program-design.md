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
3. **The engine as a client.** `semel.machine.config` names the server (`cache.server
   host:port`, and `cache.identity`); the two hooks gain the remote path with the
   population queue and the fetch policy; the machine-derived-input audit; `cache` at the
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

## Open for review

- Whether the server's store is one SQLite index plus the node kit's object store on
  disk (proposed) or a single file format of its own.
- Whether `wantsWrite` grants are a list of identities in the server's configuration
  file (proposed) or a flag that makes every client a writer, for a first deployment
  where everyone is trusted.
- The name of the engine-side setting namespace: `cache.*` is proposed.
