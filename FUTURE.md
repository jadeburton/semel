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
  `semel-vendor init Packages --platform ios-simulator` found the five roots, vendored the
  thirteen dependencies and wrote a formula and config identical in substance to the
  hand-written ones; `semel 'base <repo>' 'build Packages --into out'`
  then produced the five archives in 17 s from the warm cache and exited 0.

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


