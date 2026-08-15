# Backlog

Concrete open items. `FUTURE.md` is for direction; this is for what is broken or owed.

IDs are stable and never reused — reference them in commits (`closes B-07`) and in
discussion. Status is `open`, `doing`, `done` or `dropped`; done items stay for a while so
their reasoning is findable, then get pruned.

## Hermeticity and determinism

**B-01** `done` — **Audit every machine-derived input into the cache key.**
`cacheKeyEnvironment` now records the SDK for the Swift tools, but that was one instance of
a class. `DefaultTools` deliberately takes tool versions from the machine; environment
variables, locale, working directory and hostname were never examined. An input that
influences output but not the key makes two different builds collide on one entry — locally
a stale result, on a shared cache a wrong build handed to everyone.
*Outcome:* the engine was already hermetic by construction — `ToolExecutor` replaces
the environment rather than inheriting it, giving a fixed PATH with HOME and TMPDIR inside
the per-run sandbox and cwd there too. Exactly one node punched through it, and does no
longer (`SwiftPackageReaderTool`). Tool versions turned out fail-safe rather than silently
wrong: `Toolchain.parseVersion` keeps the build id deliberately, and the registry refuses a
tool whose reported version differs from the key's claim. Remaining gap tracked as B-17.
Superseded in the long run by B-03, which replaces enumeration with one value.*

**B-02** `open` — **Make it hard to read outside a node's declared inputs.**
Hermeticity is load-bearing for the whole design, and nothing currently prevents a node
function from calling `xcrun`, reading an environment variable or touching the filesystem.
Ideas: route all subprocess execution through `ToolExecutor` and forbid `Process` elsewhere;
scrub the environment before exec; run with a working directory that contains only declared
inputs.

**B-03** `open` — **Run tool execution in a container.**
`ToolExecutor` runs inside a dedicated process wrapping a Docker container configured with
the toolchain, SDK and system libraries, reset between builds. The container digest then
*is* the environment: `sdk=26.5 (25F70)` becomes `image=sha256:…`, and "did we miss an
input?" stops being a question only an audit can answer. Also the natural home for the
Remote Runner role (B-30).

**B-04** `open` — **Prevent non-deterministic Dictionary iteration.**
`allTargetsNamed` iterates `externalManifests` and picks whichever package the runtime
happens to yield first when two vend the same product name — against the AGENTS.md
invariant, and now on the transitive system-library path. Preferred approach, in order:
(a) take `[(String, Value)]` rather than `[String: Value]` in the few functions that produce
ordered output; (b) a test that builds the same project in two subprocesses and diffs the
results byte-for-byte, since hashing is seeded per process — this catches every order
dependence at once, and doubles as the determinism probe in B-11; (c) a source-scanning test
as a backstop. A wholesale `DeterministicDictionary` is judged high-cost and low-yield:
most dictionaries here are accumulated into, which is safe.

**B-05** `open` — **Environment-perturbation fuzzing for cache keys.**
Run a node twice varying something deliberately *not* in the key — `TMPDIR`, cwd, locale,
hostname, wall-clock. Any output difference means the key is under-specified. The systematic
version of how the SDK bug was found; belongs in the test suite, run once per node type.

**B-17** `open` — **`ToolDescriptor.recursiveHash` is designed but never populated.**
The slot exists on every tool descriptor and is read from
`properties["toolDescriptor.recursiveHash"]`, but nothing ever sets it, so it is always nil.
It is the intended place for a hash of the tool binary itself, which would close the
remaining gap after B-01: two different binaries reporting the same version string
currently share a cache key. Narrow, and B-03 subsumes it.

## Swift package conversion

**B-06** `open` — **Verify vendored dependency versions.**
`ISSUE:` at `SwiftFormulaConverter.swift:183`. A `sourceControl` dependency resolves to a
vendored sibling directory with no check that its contents satisfy the manifest's version
requirement. Needs a provenance file per vendored package (identity, URL, revision,
version), written by a `semel vendor` tool that reads `Package.resolved`. Staged behaviour:
no provenance at all → warn once; provenance present but version unsatisfied → fail.

**B-07** `open` — **Registry dependencies are ignored.**
`TODO:` at `SwiftFormulaConverter.swift:189`. Neither resolved nor reported.

**B-08** `done` — **Unhelpful stall when a vendored package is missing.**
The converter reports `awaiting external packages: input:/…/GRDB.swift` without naming the
originating URL or saying that the package must be vendored there.

**B-09** `open` — **`.library(type: .automatic)` is always built dynamic.**
No static archive support; every library product becomes a `.dylib` by assumption rather
than by choice.

**B-10** `open` — **Publish only final products.**
`libBuildSystemCore.dylib` and friends appear in `output:` though they are internal. A
product is an intermediate iff another discovered package consumes it — roots of the
dependency DAG are the deliverables. Nesting is *not* the right test: it misclassifies
`MyLibrary`, a sibling of `MyApp` consumed by it. Implementation is one boolean:
`SwiftFormulaConverter` already resolves its external package paths during its BFS, so it
can expose them; `ProjectFinder` unions them into an "is depended upon" set and sets
`publishProducts: false` on those `ProjectBuilder`s. Products still build and cache; they
just get no `OutputFile`.

## Cache

**B-11** `open` — **Probe determinism at write.**
Occasionally run a node twice before caching and compare. A node that is not reproducible is
marked never-cacheable. Fixes the problem at source rather than detecting symptoms forever,
and answers the question a shared cache most needs answered: which tools are safe to share.

**B-12** `open` — **Sampled re-verification of cache entries.**
Re-run entries and compare against what is stored. Must run *twice*, because a single re-run
cannot distinguish a bad cache from a non-deterministic tool. Weight by `cost × reuse`
rather than uniformly. On a shared cache, have each client ignore a small percentage of hits
and recompute: coverage is sampling-rate × fleet-size.

**B-13** `open` — **Store key material alongside each entry.**
Today a mismatch says two builds disagreed and nothing about why. Recording node type,
`codeVersion`, properties, input wire keys and hashes, and `cacheKeyEnvironment` makes a
mismatch diffable and lets keys be recomputed offline.

**B-14** `open` — **No blob GC.**
Unreferenced objects accumulate in the object store with no collector. Not urgent.

**B-15** `open` — **Cache abstraction behind a client interface.**
Make the engine talk to the cache as though it were a separate server, without a socket or a
separate process yet. Groundwork for the Cache Server role (B-30) that can be exercised
entirely in-process.

## Performance

**B-16** `done` — **Folder manifest rebuilt a database query per child.**
Measured: pushing N files into one folder was O(N²) queries, because a manifest is rebuilt
on *every* child change and each rebuild asked every child for its pinned state
individually. Now one query per kind. 50/100/200 files went 0.30/0.99/3.39s → 0.14/0.34/0.84s,
and growth per doubling fell from ~3.4× to ~2.4×. Agreement with each type's own `isPinned`
is pinned by `test_manifestPinnedStateAgreesWithEachChildsOwn`. See B-18 for what remains.

**B-18** `open` — **Manifest rebuilds are still super-linear.**
After B-16, pushing N files into one folder still grows at ~n^1.26: every child change
re-encodes the whole manifest to JSON, hashes it and writes an object. Extrapolated, 20,000
files is still minutes. The fix is to stop rebuilding per change — mark the folder dirty and
flush before the next processing pass — but manifest freshness is relied on between mutation
and processing, so this needs care rather than a quick cache.

**B-19** `open` — **`Folder.root(named:)` builds a graph shape on every call.**
`BUG:` at `Folder.swift` ("extremely slow. TODO cache"). Every `Folder.inputFileSystem` /
`outputFileSystem` does a `findOrCreateMatchingNode`, and those are called constantly. A
cache must key on the current `DatabaseLayer` identity, or it goes stale when the database
is swapped — which every test does. Not measured yet; measure before optimising.

**B-24** `open` — **`Folder.canBeDeleted` instantiates every child's node function.**
`TODO: slow` at `Folder.swift:63`. Same shape as B-16 but on the delete path.

## Server

**B-30** `open` — **`semelserv` with three roles.**
One binary, three modes, sharing a wire protocol:
1. **Cache Server** — see `docs/superpowers/specs/2026-08-15-semel-cache-server-design.md`
2. **Remote Runner** — executes tool commands inside, or against, a container (B-03)
3. **Shared Build Server** — see
   `docs/superpowers/specs/2026-08-15-semel-client-server-design.md`
Role 3 is still wanted even with local building, because the point is a build that continues
in the background regardless of which CLIs are open — local CLI to local server. Write it as
if multiple users might share it, without the full auth apparatus for now.

**B-31** `done` — **Fix `ClangLinkerTool.asProcessOutput` port constants.**
Writes its values under `ClangPreprocessorTool.output` and `.infoLog` rather than its own.
Works only because all four constants are the same strings.

## Closed

**B-20** `done` — SDK is in the Swift tools' cache key (`e6ca4cd`).
**B-21** `done` — Object hashes verified on read (`7f59a92`).
**B-22** `done` — Vendored static archive linked into the product; `libsqlite3.dylib`
removed from the tree.
**B-23** `done` — `SwiftPackageReaderTool` no longer overrides HOME and TMPDIR back to the
real machine, closing the only hole in the executor's sandbox.

## Not doing

**B-40** `dropped` — Subtree-scoped `reset`. Moot: users no longer share one graph.
**B-41** `dropped` — Scoping or privilege for `debug`. Moot for the same reason.
