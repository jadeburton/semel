# Semel as a shared cache, not a shared build server

**Status:** design agreed, not yet implemented
**Date:** 2026-08-15
**Relationship:** an alternative to `2026-08-15-semel-client-server-design.md`, and the
recommended one. That document is retained: its frame design and push-protocol reasoning
carry over, and the analysis of why a shared graph is expensive is worth keeping.

## The inversion

The client/server design puts one server in charge of the graph, the engine and the
store, with N thin clients pushing sources and receiving artifacts. This design keeps
Semel as it is — a full engine on each developer's machine — and reduces the server to a
**shared cache** that every instance reads from and writes to.

The motivating argument is CPU: a central build server is limited to the cores in one
machine, while N local engines scale with headcount. That is true, but it is not the
strongest argument, and there are two better ones plus one serious cost.

## Why this is the better first target

**Cross-user reuse survives.** That was the headline reason for a shared graph. If one
developer compiles GRDB and another has identical inputs, the second gets the first's
result either way — as a shared node in one design, as a shared cache key in this one.
The benefit is preserved; the machinery to get it is an order of magnitude smaller.

**It degrades gracefully.** Cache server down means slower builds. Central build server
down means nobody works at all.

**It dissolves two of the three subsystems.** The client/server design decomposed into
(1) the split and protocol, (2) artifact subscription, (3) file watching and working-copy
sync. Building locally deletes (2) and (3) outright — your artifacts are already on your
disk. The observation that "this is really a filesystem-synchronisation problem" was
correct, and the way to win that problem is not to have it.

**Most of the specced protocol goes away.** No path authorisation, no per-user home
directories, no transactions, no batches, no manifests, no sessions, no reconciliation, no
concurrent mutation of one graph.

## What is already built

`CacheEntry` is already `hash → content` with `cost` and `timestamp`. The cache key is
already a pure function of node function type, `codeVersion`, node properties, and every
static and dynamic input wire — key *and* value, because the wire key is the file's path
and tools embed it.

The hooks are `loadCachedOutputs(cacheKey:)` and
`saveCacheForAllInputsAndOutputs(cacheKey:processingDuration:output:)`. A remote tier
slots in behind exactly those two calls; nothing else in the engine needs to know.

## Two tiers, because a cache entry holds references

This is the structural fact that shapes everything. A cache entry is a `ProcessCacheEntry`
— `outputValues` plus `inputWireExpectations` — and `outputValues` is
`[String: NodeValue]`, where `NodeValue.value` carries a `DataToken`. And:

```swift
public typealias DataToken = DataObjectHash
```

So a cache entry contains **hashes, not bytes**. The object bytes live in
`DataObjectStore`, keyed by content hash. A cache hit is therefore useless on its own: you
also need every data object the entry references.

That gives the standard two-tier shape (the same split Bazel draws between its action
cache and its CAS):

- **Action cache** — cacheKey → `ProcessCacheEntry` JSON. Small, a few hundred bytes.
- **Object store** — contentHash → bytes. Large; object files, modules, binaries.

## Protocol

Same frame as the client/server design — JSON section plus optional binary body, no magic,
big-endian, reserved `event` kind — because it already suits this and there is no reason
to invent a second one.

| Request | Payload | Response |
|---|---|---|
| `Hello` | clientID, protocolVersion, wantsWrite | accepted / read-only / rejected |
| `GetCacheEntry` | cacheKey | entry JSON, or miss |
| `PutCacheEntry` | cacheKey, entry JSON, cost | stored |
| `HasObjects` | [hash] | missing: [hash] |
| `GetObject` | hash | → bytes |
| `PutObject` | hash → bytes | stored |

`HasObjects` earns its place here in a way it did not in the push protocol. There, merge
semantics meant asking about three hashes. Here a single cache hit may reference many
objects, and the client must discover which it lacks before fetching — one round trip for
the whole set.

`PutObject` carries the client's declared hash and the server verifies it, for the same
reason as before: the client already computed it, and sending it converts silent
corruption into a loud mismatch.

## A remote hit is not free, and `cost` is how you decide

A local cache hit costs a database read. A remote hit costs a round trip plus fetching
every referenced object that is missing locally — potentially megabytes of object files.
For a cheap node over a slow link, recompiling may genuinely be faster.

`CacheEntry.cost` already stores the milliseconds of compute the entry saves, and
`saveCacheForAllInputsAndOutputs` already refuses to cache anything under 15 ms. That is
exactly the input a policy needs: compare estimated fetch time against `cost` and build
locally when fetching would lose. Not needed for a first version on a LAN; the data is
already there when it is.

## The correctness prerequisite

`Cache.swift` states the rule:

> Keying on a partial input set would produce a key that collides with a different set of
> inputs — **the one failure mode a cache must never have.**

Sharing raises the stakes enormously. Locally, an under-specified key gives *you* a stale
result and you notice. Shared, it silently hands everyone else a wrong build, and it looks
correct on the machine that produced it.

**There is a live instance of this today.** The Clang tools take the SDK from
configuration, so it is in the key:

```swift
sdkPath = properties["sdkPath"]     // ClangPreprocessorTool, ClangLinkerTool
```

The Swift tools resolve it from the machine at process time:

```swift
func resolveSDKPath() -> String?    // shells out to xcrun --show-sdk-path
```

That value is not in the cache key. `SwiftCompilerTool` and `SwiftLinkerTool` compile
against whatever SDK the machine has, while the key says nothing about it. Two developers
on different Xcode versions produce different object files under identical keys. Today
that is mild local staleness; under a shared cache it is silent cross-user corruption.

**This must be fixed before any shared cache is enabled**, and it should be treated as a
representative of the class rather than a one-off. Before sharing, audit every input that
comes from the machine rather than from the graph: SDK path and version, tool versions
(`DefaultTools` deliberately takes these from the machine), environment variables, locale,
and anything else `process.run()` can observe that the key does not name.

## Trust

Anyone who can write to the cache can poison everyone who reads it. `Hello` carries
`wantsWrite` so the server can grant read-only by default, and the deployment decides who
writes — the usual answer being that CI writes and developers read. This is a policy
choice to make deliberately rather than discover, and it is the main reason remote
*execution* is considered safer than shared caching by untrusted clients.

Authentication is deferred as in the other design: `Hello` asserts an identity the server
trusts, over a LAN or VPN, with the field present so real auth is not a breaking change.

## Eviction and sizing

The local cache is `cacheEntryLimit = 500` entries with LRU by `timestamp`, trimmed on
every insert, stored in the same SQLite database as the graph.

A shared server needs its own store and a much larger budget, and should evict on
`cost`-weighted LRU rather than plain recency — an entry that saves 90 seconds of
compilation is worth keeping over one that saves 20 ms, regardless of which was touched
more recently. The `cost` column already exists for this.

Objects and entries evict independently, so an entry can outlive an object it references.
That is fine and must simply be handled: a `GetCacheEntry` hit whose objects are missing
degrades to a miss, which is why `HasObjects` is consulted before the client commits to
using an entry.

## Client integration

Behind the two existing hooks:

```
loadCachedOutputs        local miss → GetCacheEntry → HasObjects → GetObject × K
                                    → populate local store → return ProcessOutput
saveCacheForAllInputs…   local write, then PutObject × K → PutCacheEntry
```

Remote writes must not block the build. A failed or slow cache server should make builds
slower, never incorrect and never stuck — so remote population happens off the processing
path, and every remote failure degrades to "cache miss".

## Testing

- **Key stability** — the same inputs on two machines produce the same key, and any
  machine-derived input that is not in the key is a bug. This is the test that protects
  everyone else.
- **Cache protocol handlers** against a real in-memory store, no socket.
- **Two-tier consistency** — an entry whose objects are missing degrades to a miss rather
  than producing a broken `ProcessOutput`.
- **Degradation** — with the server unreachable, builds still complete, only slower.
- **End-to-end** — machine A builds and populates; machine B, with a cold local cache,
  gets a hit and produces byte-identical output.

That last one is the acceptance test for the whole design.

## Known consequences

- **Every developer needs a full toolchain.** Not a concern for Macs with Xcode.
- **No central visibility.** The server knows key → bytes and nothing about who is
  building what or what is failing. The "only publish artifacts from a green build" idea
  needs a central view of build state and does not fit this design.
- **A poisoned entry is sticky.** It persists until evicted or explicitly purged, so the
  server wants a purge-by-key operation before it is trusted in anger.

## Relationship to the central-server design

The cache protocol is close to a strict subset of the client/server protocol: the frame is
identical, and `PutObject`/`GetObject`/`HasObjects` are `StoreFile`/`GetContent` under
different names. Building this first therefore forecloses nothing, while building the
central server first would mean constructing a great deal of machinery — path
authorisation, transactional batches, artifact sync — that this design does not need.

**Remote execution** — a central server dispatching compile jobs to a worker pool — is the
third option, and gets CPU scaling *and* central state. It is substantially more complex
than either design here and should wait until a shared cache is demonstrably not enough.
