# Semel R1

## Planning and strategy

- Convert to client-server architecture and daemon

- Central cache server 

- Get it working with large swift package that has complicated dependencies and targets

  Done (2026-09-13): IceCubesApp's thirteen packages — five consumption roots, thirteen
  external packages including swift-cmark's C targets — build for the iOS simulator under
  one formula (`C1/icecubes/Packages/semel.fmla`): 1,886 files pushed in 8 s, a cold build
  of 271 cache entries in about 4.5 minutes wall clock for 25 minutes of tool time, five
  archives, no errors. Nodes are shared across the roots: 26 Swift compiler nodes for 26
  targets. What it took is in the commits from 5ffd0af to c31917e.

  The loop closed the same day (B-57 to B-59): on a fresh copy of the packages,
  `semel-swift prepare Packages --platform ios-simulator` found the five roots, vendored the
  thirteen dependencies and wrote a formula and config identical in substance to the
  hand-written ones; `semel 'base <repo>' 'build Packages --into out'`
  then produced the five archives in 17 s from the warm cache and exited 0.

  Next: the app itself. A spike on 2026-09-14 built a SwiftUI app for the simulator from a
  hand-written formula with no engine change — three products under `Hello.app/` — and it
  installed and launched. The design for resources and the Xcode project is in
  `docs/superpowers/specs/2026-09-14-semel-app-bundles-design.md` (B-63 to B-65).
  Parts 1 and 2 landed the same day: tree products, and the `SemelApple` nodes. HelloApp
  now carries an asset catalog (icon, image, accent color) and a two-language string
  catalog, its Info.plist is built from the project's file and actool's partial one, and
  the app shows the compiled image and the localized title in the simulator.

  2026-09-15: IceCubesApp itself, from its Xcode project. `XcodeProjectConverter` reads
  the project file and its xcconfig, evaluates the settings, walks the application's
  three synchronized folders and emits the bundle; every package the project references
  is included and consumed through its module and object trees. On a fresh copy of the
  repository — 5,616 files, thirty packages vendored with `xcodebuild
  -resolvePackageDependencies` — `build icecubes-app --into out` produced `Ice Cubes.app`
  (a 57 MB executable, Assets.car, two icon PNGs, nineteen `.lproj` folders, fonts and
  sounds, the Info.plist with actool's icon keys), with no errors, and `simctl install`
  plus `launch` showed the app's onboarding screen loading instance suggestions from the
  network. Three things fell out on the way: a symbolic link back up a package tree
  walked without end, an included formula's own includes were not followed, and a
  dependency only a test target uses was waited for. Later the same day the four
  extensions followed — each a bundle under `PlugIns/`, the simulator's plugin registry
  listing all of them — and `prepare` learned a folder holding a project. The loop for an
  app is now the same two commands as for a package tree: `semel-swift prepare <clone>
  --platform ios-simulator`, then `semel 'base <parent>' 'build <clone> --into out'`.

- Get it working with large c or c++ project

- Maybe, if at all technically possible, a tool to convert a makefile or cmake file to a Formula file. Or even a Node that does it. Technically this is trying to convert imperative code to functional, but a "pure" makefile can in fact be functional. Cmake still has add_xxx methods and a mess of a syntax.

- Make github repo public

- Remote execution of tools. Ideally in docker containers running wherever.

- Periodic cache integrity check: randomly compare the cache with computed output and if they differ, reset the entire cache.

- Done (B-29): a Semel version marker in the database resets the graph on mismatch, and the
  schema is fingerprinted from `sqlite_master` against what the code would create — a
  mismatch stops the launch and names the file to delete. A hash over the Semel code was
  considered and declined: it would reset on every rebuild of Semel, comment changes
  included, so nobody developing Semel would ever see a cache hit.

- Rollback of all input file changes if any Node enters an error state as a result, thus guaranteeing the build is always green.

## Settled direction

- Multi-user: a full engine on each developer's machine, sharing a central **cache
  server** — decided 2026-08-15, see
  `docs/superpowers/specs/2026-08-15-semel-cache-server-design.md`. Each machine keeps its
  own graph, one user per graph; the existing local cache stays as the near tier in front
  of the remote one, so a local hit never pays a round trip. Deduplication across users
  happens at the *cache*, not at node identity: same content, same project-relative path,
  same settings → same cache key → one compilation, on whichever machine got there first.
  Prerequisites, in order: canonical sandbox layout plus
  `-ffile-prefix-map`/`-debug-prefix-map` so outputs are mount-independent (B-49 — every
  developer has a different checkout path); mount prefix stripped from cache-key wire
  names (the project-relative part stays — that distinction is the Cache.swift
  path-collision lesson); a shared cache with real eviction and GC (B-14, B-15, B-30
  role 1).

- Superseded: one shared graph holding every user as a subtree of a single input/output
  file system (`input:/jade/my-branch/src/…`, one node per path). Recorded here as settled
  on 2026-09-09 by mistake — it is the shared-build-server model the cache-server spec
  replaced, and it drags in path authorisation, per-user output subscriptions, working-copy
  sync and a graph that is never globally idle. None of that exists when each engine is
  local. The shape survives only as B-30 role 3: a *local* background daemon serving local
  CLIs.

- A fully content-addressed graph (immutable nodes, git-style blobs/trees/refs, graph
  doubling as its own cache — the Nix/Buck2 model) was considered for cross-user dedup and
  declined. It shares bookkeeping as well as compute, but every edit appends nodes forever
  where the mutable graph updates in place, and it moves incrementality out of the resident
  graph into an evaluation phase — against the core vision of a living graph that reacts to
  pushes. With local engines the bookkeeping is per machine anyway, so there is nothing
  left for it to buy.

## What the tutorial taught us

`docs/tutorial/first-node.md` (2026-09-21) was written by walking every step through
against the binaries, and it is read here as evidence about the design: wherever the
document has to explain, warn or apologise, the reason is in Semel. The correctness
principles hold up — hermetic input, identity by spec, no defaults — and the friction is
where a person pays for one of them by hand, or where the engine holds what the person
needs and has no channel to say it. Three items are filed (B-91 to B-93); the rest are
questions about settled decisions, recorded so they are argued rather than re-discovered.

- **The engine has no output channel (B-91).** The protocol carries products and errors;
  everything else leaves through `Debug.log`, compiled out of a release build. So the
  tutorial's Part 2 — the one that shows the work Semel does not do — needs three
  terminals, a debug build and two internal log lines, and even the engine's own count
  (`batch: N scheduled, M computed`) does not separate a cache hit from a recomputation.
  "Why did this rebuild?" is the first question anyone asks a build system whose promise
  is *never twice*, and nothing in the design answers it.

- **A missing file is a state nobody is told about (B-92, fixed).** A `StaticFile` nobody
  pushed publishes `noValue(.initializing)` — no value has ever been produced there, and
  with no inputs, nothing ever will. That is not a failure, so no report named it: the nodes
  below it publish `inputNotProduced` and were passed over too, and what a reader got was
  `[missing]` in `ls` and one `Error` beside the product. The tutorial's `push clang.cfg`
  step exists because `build` pushes one folder and the formula reaches outside it with
  `<../clang.cfg>`; forget it and every tool named a missing setting while nothing named the
  missing file. B-71 was this problem, fixed for one file; B-92 is the report line for all
  of them — `clang.cfg has not been pushed`, with the chain below it counted. What decides
  the one exception is the port, not the node's type: `ConfigMerger.override` declares that
  it reads an absent value as nothing to add, because an override file nobody wrote is the
  expected state. Every other port, the merger's own `base` and the filter's `input`
  included, is a port whose file the formula says must exist.

- **`reset` threw away the valuable state (B-93, fixed).** The graph is rebuildable from
  the input plus the cache, and the cache is content-addressed — but `reset` also deleted
  the cache, which was the only reason it cost a cold build of everything in the home.
  That cost is what made leaving the tutorial a fifty-line, order-dependent section: a
  graph that still holds a node of a type the server no longer links is a dead end (B-83),
  and the way out was expensive. `reset` keeps the cache, `reset --cache` is the command
  that discards it, and the graph a reset discards is copied aside rather than lost.

- **No defaults is right; a person paying for it by hand is not.** The configuration
  design (2026-08-30) argues this well and accepts "a real ergonomic cost". The guarantee
  needs the values declared in the input file system; it does not need a person to type
  them, and it does not need them in the same file as the project's intent. Tool
  version, SDK path and architecture are facts about the machine, and they change with
  it; `cStandard` and the deployment target are the project's, and belong in the
  checkout. One file holds both, which is why the end-to-end harness needs a `.template`
  with placeholders and why the reader adds seven lines by hand after being told not to
  write the file (`tools clang` now prints the machine half ready to paste, B-86; the
  project half is still typed). Swift has the right shape already (`prepare` writes the machine facts);
  `ConfigMerger` and "variants are files" mean a generated machine file merged with a
  checked-in project file fits the design as it is. Separately: every hand-written
  formula repeats `rawConfig()` / `config(prefix:)` / `ConfigFilter` wiring although the
  prefix is derived from the node's type name (`SettingNamespace`), so the engine already
  knows which slice a `ClangCompiler` wants.

- **A node type's identity is stored three ways.** A hand-assigned `kind` integer, the
  type name inside every stored `graphSpec`, and the schema fingerprint. Renaming a type
  already forces the database to be deleted (B-29), and `TypeRegistry` already looks
  types up by name; whether `kind` still earns its place is worth asking. Hand-assigned
  numbers collide across branches — the backlog IDs did exactly that in the same week.

- **Isolation is per user, work is per project.** B-40 (a scoped `reset`) was dropped as
  moot because users no longer share a graph; projects still do. Pushes are base-relative,
  so two folders both named `hello` under different bases land at the same `input:/hello`
  (read from `FilePlugin`, not run). "Extensible" in the README overstates what is
  possible: node types are compiled into the server and their identity lives in a
  long-lived database, so every experiment leaves something in the real graph. A
  throwaway home (`SEMEL_HOME`, or a `--home` flag on both binaries) would make the
  tutorial's clean-up "delete the folder".

- **The node API exposes the engine's internals.** `inputValues` is an unordered
  dictionary, so every author has to remember to sort (the tutorial does; B-04 is the
  same class of bug); a sorted list on the API would remove it. `.required` blocks on a
  pending wire but not on an errored one, so each node invents its own missing-value
  policy — `ConfigFilter` skips, `LineCounter` throws — where the descriptor could state
  it. Authors import `SemelDatabaseModels` for `NodeRecord`, repeat the `thisNode`
  boilerplate, and are pure only by discipline.

- **The 15 ms cache floor is a wall-clock decision.** Whether an entry exists depends on
  how long processing took (`Cache.saveCacheForAllInputsAndOutputs`), so a shared cache
  fills differently with machine speed and load. Harmless to correctness, odd in a
  project built on determinism, and it made the tutorial's own node uncacheable. A
  declared per-type property would be predictable.

- **The easiest spelling in the formula language is the wrong one.** `%%f%%` names a wire
  after the mounted path and so puts the path into the product; `%%f.0%%` is the
  capture. The mistake was made in this tutorial's own spec and caught only by the
  two-home byte comparison. B-49 makes the tools mount-independent; a template can bring
  the mount path straight back.


