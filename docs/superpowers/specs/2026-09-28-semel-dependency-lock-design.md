# Locking vendored dependencies by content hash (B-06)

Status: design and as built, 2026-09-28. FUTURE.md's B-06 entry made most of the
decisions — a checked-in lock beside the vendored folder, not inside it; an enforced
content hash, a recorded-only version and origin; a mismatch stops the build naming the
expected and the found hash; `prepare` writes the lock when it vendors. This records the
ones it left open and how the pieces fit.

## What the lock is for

Not cache correctness: a vendored file is a `StaticFile` whose content hash is a wire
value, so an edit to vendored GRDB already changes the key of everything downstream. The
lock buys consent. Without it a change is absorbed — the graph rebuilds and succeeds, and
nobody is told their dependency moved. With it the build stops: "expected `abc…`, found
`def…`".

## Decisions

- **One lock per dependency, beside it.** `Dependencies/GRDB.swift.semel-lock` locks
  `Dependencies/GRDB.swift`. Per dependency rather than one file for all, so the diff of an
  update touches the one file of the one package that moved, and `prepare` rewrites a lock
  without reading or merging anyone else's. Not a dot-file: a push leaves out every name
  starting with a dot, and the lock has to reach the graph as a `StaticFile`.

- **The text:**

  ```
  # Semel dependency lock (B-06): `content` is enforced, the other lines are recorded only.
  content   sha256:4f0c…
  fold      semel-folder-content-root 2
  version   7.11.1
  revision  b83108d10f42680d78f23fe4d4d80fc88dab3212
  origin    https://github.com/groue/GRDB.swift.git
  ```

  `content` and `fold` are required; `version`, `revision` and `origin` are written when
  the resolver said them (a branch pin has no version). The `fold` line is the one addition
  to the entry's sketch: the root is the hash of a stated format with a version tag
  (`FolderContentRoot.formatTag`), and recording which fold a lock was taken under is what
  lets a lock the format moved under read as "cannot be compared" rather than as "the tree
  moved". The reader is strict — an unknown key, a key said twice, an empty value or a
  `content` without its `sha256:` is refused by line — because the file is edited by hand
  and a misspelt line would otherwise be one nobody reads.

- **Reader, writer and the disk fold live in `SemelNodeKit`** (`DependencyLock`,
  `FolderContentRoot.root(ofFolderAt:)`): the converter in `SemelSwift` reads it and
  `semel-swift` writes it, and both reach the node kit without a toolchain package importing
  the engine. The rule naming a repository's folder (`GRDB.swift` from its URL) moved there
  too, as `DependencyLock.folderName(forRepositoryURL:)`, so the converter, the Xcode
  emitter and `prepare`'s pin matching read one rule instead of three copies.

- **The converter checks.** `SwiftFormulaConverter` already resolves `Dependencies/<name>`;
  it now checks every package folder it reads directly under `<root>/Dependencies` — the
  vendored dependencies it reaches, and the package it converts when an Xcode project's
  formula names a remote package by its vendored folder. Two dynamic ports: `dependencyLocks`
  (the lock `StaticFile`, by the lock's path) and `dependencyContentRoots` (the folder's
  `contentRoot`, by the folder's path). The locks are demanded alongside the manifest
  readers, so they arrive while the manifests do; a folder's root is demanded only once its
  lock has arrived with something in it. The comparison is `DependencyLockCheck`, which
  returns a typed outcome — waiting, passed (naming the unlocked folders), or failed with a
  `Problem` per package: `mismatch`, `foldChanged`, `unreadable`. The converter's error is
  the rendering of those.

- **A missing lock is a notice, not an error.** Every tree vendored before this change is
  in that state, and so is one vendored by hand — and the entry says "absent → warn once".
  The conversion goes on and posts one line naming the unlocked packages and that
  `semel-swift prepare` writes a lock beside each. A toolchain node cannot reach the
  engine's notice reporter, so `SemelNodeKit` gained `NodeNotice`, a swappable closure the
  engine points at `BuildEngine.notice` when it is built; the server already carries those
  lines to the client. The line is posted once per conversion that produces a formula, not
  on the passes that wait, and not at all on a cache hit. Not wiring the root of an unlocked
  folder keeps a tree without locks from being woken by every edit below its vendored
  folders.

- **What the hash is over.** The `contentRoot` the `Folder` publishes for the pushed copy,
  which is what the converter compares with. `prepare` computes the same root from the disk
  — the same `document(of:)` and the same `Sha256` the engine interns with — over what a push
  would push: `ExternalFileSystemLister`'s listing (the one `push` matches with), which leaves
  out every dot-name (a copied checkout's `.github`, `.gitignore`, `.swiftpm`; `.git` and
  `.build` are not even copied) and follows a link unless it points above itself; and
  without a subfolder holding no file at any depth, since a push creates a folder only on
  the way to a file. `DependencyLockFoldTests` (SemelCore) pushes a tree with all of those
  through the engine and compares the two roots.

- **`prepare` writes the lock** beside each copy after all of them are in place, with the
  pin SwiftPM's `Package.resolved` gives for the checkout — found by the checkout's folder
  name, derived from the pin's `location` by the shared rule. For a package tree that is
  `<root>/Package.resolved` after `swift package resolve`; for an Xcode project,
  `<project>/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. No resolved file,
  or a pin not found, writes a lock with `content` and `fold` only. A name two roots both
  vendor is locked once, over the copy that stayed, with the later pin.

## The messages

A mismatch:

```
SwiftFormulaConverter: input:/repo/Packages/Dependencies/GRDB.swift is not the tree its lock records.
  lock:     input:/repo/Packages/Dependencies/GRDB.swift.semel-lock (version 7.11.1, from https://github.com/groue/GRDB.swift.git)
  expected: sha256:abc123…
  found:    sha256:def456…
If the change is meant — the dependency updated or patched — `semel-swift prepare` on the project vendors
it again and rewrites the lock, or put the found hash on the lock's `content` line. If it is not, vendor it
again: the copy is not what was locked.
```

A missing lock:

```
No lock beside 1 vendored package (GRDB.swift): nothing checks that it is what was vendored. `semel-swift prepare` writes a <name>.semel-lock beside each.
```

## As built — what remains

- **A file removed from disk stays in the graph.** A push only adds, so re-running
  `prepare` after an update that deleted files leaves the old files in `input:`, and the
  engine's root no longer matches the fresh lock. That is the lock doing its job — the
  build is reading a tree the lock does not describe — but the way out is `rm` of the stale
  path (or a fresh home), and the message does not say which file differs. A per-file
  report would need the lock to carry more than a root.
- **A lock removed from `input:` is a deleted source.** A lock nobody pushed is tolerated —
  the converter's `dependencyLocks` port is in `inputPortsToleratingAbsentValue`, so the
  report does not name it — but one pushed and then `rm`'d is named "was deleted" on every
  report while the converter wires it, as `ErrorReport` names every removed source. Deleting
  the file from disk does nothing (a push only adds), so the lock goes on being checked.
- **The version is recorded, never checked** against the manifest's requirement; the
  converter's `ISSUE:` says so.
- **Checked by hand on the Semel-self tree** (2026-09-28): with the lock `prepare` wrote the
  build settled with no errors; with its `content` line zeroed the converter failed with the
  message above, `found` being the root `prepare` had recorded; with no lock on disk and a
  fresh home it built, exported and posted the notice once.
- **A folder's intermediate root.** During a flush a folder can publish an intermediate
  root before the settled one (B-26, item 3); the converter is then woken twice and may
  fail on the first. The flush drains before the pass selects, so the settled root is what
  the report shows.
