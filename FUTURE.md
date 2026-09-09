# Semel R1

## Planning and strategy

- Convert to client-server architecture and daemon

- Central cache server 

- Get it working with large swift package that has complicated dependencies and targets

- Get it working with large c or c++ project

- Maybe, if at all technically possible, a tool to convert a makefile or cmake file to a Formula file. Or even a Node that does it. Technically this is trying to convert imperative code to functional, but a "pure" makefile can in fact be functional. Cmake still has add_xxx methods and a mess of a syntax.

- Make github repo public

- Remote execution of tools. Ideally in docker containers running wherever.

- Solve the problem of code changes invalidating the entire cache and database. I.e. Semel code itself should have some kind of hash over it and this is used to invalidate caches. 

- Periodic cache integrity check: randomly compare the cache with computed output and if they differ, reset the entire cache.

- Database migration: probably just clear all caches and rebuild everything. Maybe the program could dump the SQL schema as a blob of text on launch and compare with previous to detect schema change.

- Rollback of all input file changes if any Node enters an error state as a result, thus guaranteeing the build is always green.

## Settled direction

- Multi-user: each user (and branch) gets a subtree of the one input/output file system —
  `input:/jade/my-branch/src/…` — and the graph keeps one node per path. Deduplication
  across users happens at the *cache*, not at node identity: same content, same
  project-relative path, same settings → same cache key → one compilation. Prerequisites,
  in order: canonical sandbox layout plus `-ffile-prefix-map`/`-debug-prefix-map` so
  outputs are mount-independent; mount prefix stripped from cache-key wire names (the
  project-relative part stays — that distinction is the Cache.swift path-collision lesson);
  a shared cache with real eviction and GC (B-14, B-15, B-30 role 1).

- A fully content-addressed graph (immutable nodes, git-style blobs/trees/refs, graph
  doubling as its own cache — the Nix/Buck2 model) was considered for multi-user dedup and
  declined. It shares bookkeeping as well as compute, but every edit appends nodes forever
  where the mutable graph updates in place, and it moves incrementality out of the resident
  graph into an evaluation phase — against the core vision of a living graph that reacts to
  pushes. Revisit only if per-user node counts actually hurt after the cache-level dedup
  exists.


