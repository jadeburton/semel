# Locked folders: a lock is a write barrier, and a batch is all or nothing

Status: design, for review before any code. Follows the 2026-10-05 discussion of where the
engine's responsibility ends.

## The problem

The engine's input changes only by a push, and a push is an explicit action: that is the
principle that keeps `input:` a private file system rather than a view of the disk. The
watcher (B-126) did not change the contract, but it changed who issues the pushes: with a
watcher running, a `git checkout`, a generator, an editor's format-on-save, a re-vendored
dependency and a hand edit under `Dependencies/` all reach `input:` within two seconds of
touching the disk. Nothing in the engine distinguishes a change a person meant from one
they did not notice, and the place where that matters most is a dependency folder: a copy
that moves under the build is a version mismatch nobody asked for.

The lock (B-06) was built for exactly this and stops short. `Dependencies/<name>.semel-lock`
records the folder's content root, and the converter compares the two and stops the build
when they differ. But the check runs *after* the change has landed: `input:` already holds
the moved copy, the previous settle's products are already stale in the graph, and the
report can say that the root moved but not which paths moved it, because the engine kept
no record of what the batch changed (B-06's "what remains").

Four ideas were on the table: lock whole folders; treat a dependency as an opaque unit with
one hash; require an opt-in for pushing some files; detect a push that breaks the build and
roll back to a checkpoint. This design takes the first as the rule, gets the second from
the first plus the batch, declines the third, and makes the fourth explicit.

## Decisions

- **A lock is a write barrier, enforced at `commit`.** A folder `F` is *locked* when
  `F.semel-lock` is in `input:` beside it, the rule the converter already uses to find a
  lock. A batch that changes anything below a locked folder — a push, a removal, a link —
  must also replace that folder's lock with one whose `content` is the folder's content
  root *after* the batch, or remove the lock. Otherwise the batch is **rejected whole**: no
  path it touched stays changed, the engine is not woken, and the reply names the folder,
  the lock, the root the lock records, the root the batch would have produced, and every
  path of the batch below that folder. A locked folder therefore changes only by an action
  that brings its lock, which today is `semel-swift prepare` (B-138 writes the copy and the
  lock together, and a push of the tree carries both in one batch). The check is on the
  outermost `commit`; a push outside any batch is a batch of one and is checked the same.
- **The dependency stays a tree of files; its unit of change is the batch.** The content
  root in the lock is already one hash over the whole folder — the zip's hash — and the
  batch is already how several changes land together. What this adds is that the batch
  either lands with the lock or not at all. The folder is *not* made opaque to the build:
  a compile depends on the two headers it reads, not on the dependency, and that is where
  incremental builds come from. All-or-nothing on the way in, per file inside.
- **No opt-in per file.** The failures the watcher invites come from two places: dependency
  folders, which the barrier covers, and generated or temporary files, which the filter
  covers (`--except`, the always-excepted export destination, the lister's dot-name rule).
  A person saving a file in their own source tree is the explicit action; asking them to
  declare the file first would tax the case the watcher exists for and prevent nothing the
  two rules above do not. One refinement: **the watcher does not watch a locked folder**
  unless `--only` names it, says so on the launch line, and names `prepare` as the way such
  a folder changes. A change under a locked folder that the watcher is told to watch anyway
  goes through the barrier like any other batch and is rejected without its lock.
- **Rollback is explicit, and the barrier's own mechanism gives it for free.** To reject a
  batch whole, the engine keeps, per open batch, a *journal*: for each path the batch
  touches, what was there before (a content hash and mode, a link target, a folder, or
  nothing). Rejecting the batch replays the journal backwards. The same journal is what a
  `checkpoint` and `restore` need: `checkpoint [<name>]` records the input root's content
  root (one hash; every object below it is already in the store) and `restore <name>`
  pushes `input:` back to that tree in one batch, which costs almost nothing because every
  node downstream hits the cache. Nothing is automatic: a broken build is the information a
  person wants, the watcher already exports only after a clean settle so the last good
  products stay on disk, and an engine that rolled back on its own would hide the error it
  should be showing.
- **The engine checks the lock's `content`; `prepare` owns everything else in it.** The
  version, revision, origin and artifact checksums the lock records are the package
  manager's (B-138, AGENTS.md's deliberate choice). The barrier reads one line of the lock
  and compares one hash. A lock that does not parse is an error at `commit` naming the line,
  as `DependencyLock.parse` already names it, and the batch is rejected: a folder with a
  broken lock is locked shut rather than open.

## What a batch does now

Today `beginBatch` only defers the engine's wake-up and `endBatch` sends one signal; every
push and `rm` inside the batch lands in `input:` as it arrives. That stays, with the
journal added:

1. `beginBatch` opens a journal for the session (nested begins share it; the outermost
   `commit` closes it).
2. Each push, link push or removal records, before it writes, the prior state of the path
   it changes, once per path per batch (the first record wins; a path pushed twice in a
   batch is journaled once with what was there before the batch). The record is the same
   `TreeManifestEntry` shape a tree carries — `.file(hash:mode:)`, `.symbolicLink(target:)`,
   a folder, or absent — so nothing new is invented for it.
3. The outermost `commit`:
   - Collects the locked folders the journal's paths fall under (walk up from each path to
     the first ancestor with a sibling `.semel-lock` in `input:`; a path under no locked
     folder is free).
   - For each such folder, reads the lock now in `input:` (the batch may have replaced it)
     and folds the folder's content root as the engine sees it (`FolderContentRoot`, the
     same fold `prepare` and the converter use). If the lock is absent after the batch, the
     folder is no longer locked and the change is free. If the lock parses and its
     `content` equals the fold, the change is allowed. Otherwise the batch is rejected.
   - On rejection: replays the journal backwards under one database transaction, so
     `input:` is what it was before `beginBatch`; sends no wake-up (nothing changed); and
     answers `commit` with a typed error, `batchRejected(folder:lock:expected:found:paths:)`.
     The paths are the journal's below that folder, so the report says which files moved
     the root. A push outside a batch gets the same answer from its own implicit commit.
   - On success: closes the journal and sends the one coalesced signal as today.
4. Until `commit`, a direct read or a `list` sees the batch's state, as it does today; a
   rejected batch leaves no trace of it. A connection that closes with a batch open is
   committed, as today, and goes through the same check.

The content-root fold at `commit` is the cost. `HeldTree` already folds a folder's roots
for the manifest-diff push (B-132), and the settle's flush folds dirty folders (B-139's
transaction), so the fold is one read of a subtree whose entries the push just wrote; on a
re-vendor of GRDB it is a few thousand lines, well under the push itself. A batch that
touches no locked folder pays nothing but the journal's record per path, which is one
row per path in the batch's transaction.

## Why a journal and not a staging area

The other way to make a batch all-or-nothing is to stage its writes and apply them at
`commit`. That gives the same guarantee with a different cost: every read during a batch
has to choose between the staged and the committed tree, the manifest-diff push's
`contentRoots` request has to answer from the staged one, and the engine's folders and
ports would see a second place files can be. The journal keeps one tree, makes a rejected
batch a replay rather than a second code path, and is the record `restore` wants anyway.

## The commands

- `commit` fails with the rejection above. `build` and the watcher print it as they print
  any error; the watcher's batch is simply gone and the next quiet interval tries again
  with whatever the disk holds then (a re-vendor's lock usually arrives within the two
  seconds; an edit to vendored code never brings one and is rejected every time, which is
  the point).
- `checkpoint [<name>]` records the input root's content root under a name (`latest` when
  none is given) in the graph, and prints the hash. `checkpoints` lists them.
  `restore <name>` pushes `input:` to that tree in one batch — files, links, modes,
  folders removed that the checkpoint lacks — and settles once. A restore goes through the
  barrier too: a locked folder restored to a different root restores its lock with it,
  since the lock is a file of the tree.
- `prepare` (B-138) already writes a re-vendored copy and its lock together; nothing
  changes there. A person who edits vendored code on purpose runs `prepare` to re-lock it
  (B-138 re-vendors a copy whose root differs from its lock, so the edit is overwritten —
  by design: a vendored copy is the package manager's, not the person's) or removes the
  lock to unlock the folder, which is a visible, reviewable act in the tree.

## What is not in it

- **Locking anything but folders with a `.semel-lock` beside them.** A general "lock this
  file" verb would be a second mechanism for the same promise; a person who wants a folder
  locked writes a lock for it (`DependencyLock` is text and documented), and B-138 is how
  one is kept true.
- **Partial acceptance.** A batch is one change; accepting the free paths and rejecting
  the locked ones would leave a half-applied `git checkout` in `input:`, which is the
  state this design exists to prevent.
- **Automatic rollback** on a failed settle, for the reasons above.
- **Checkpoints of `output:`.** Products are a function of `input:` and the cache; a
  restored input brings them back by itself.

## Testing

- `BatchJournalTests` (SemelCore): a batch records each path once with its prior state;
  replaying it restores files, links, modes, folders and absences; a nested batch shares
  one journal.
- `LockBarrierTests` (SemelCore): a push below a locked folder without its lock is rejected
  and leaves `input:` as it was; with a matching new lock it lands; with a mismatching new
  lock it is rejected naming both roots; removing the lock in the batch frees the folder; a
  lock that does not parse rejects the batch naming the line; a batch touching no locked
  folder is unaffected; a push outside a batch is checked as a batch of one.
- `ServerTests` (root): `commit` answers `batchRejected` over a socket with the paths; the
  engine is not woken by a rejected batch; a connection closing mid-batch is checked.
- `WatcherTests` (root): a locked folder is not watched by default and the launch line says
  so; a re-vendor (copy and lock in one quiet interval) lands; an edit under the locked
  folder is rejected and reported, and the next unrelated save still builds.
- `CheckpointTests` (root): `checkpoint`, `checkpoints`, `restore` round-trip a tree with
  files added, removed, relinked and re-moded; a restore across a lock change carries the
  lock; a restore hits the cache (no node processes).
- End to end: `swift-binary-target-app` or `netnewswire-mac` with a vendored copy edited by
  hand between the two builds: the second build's push is rejected naming the file, the
  export is the first build's, and `prepare` followed by `build` succeeds.

## Open questions for review

- Whether a rejected `commit` should leave the session's batch depth at zero (the batch is
  gone) or open (so the client can push the lock and commit again). The watcher wants
  zero; a person at the prompt might want to add the lock and retry. Proposed: zero, and
  the error says so, because a batch that half-exists is the state being avoided.
- Whether `checkpoint` names live in the graph database or as files in the tree. Proposed:
  the database, since a checkpoint is a property of this engine's `input:`, not of the
  tree, and a tree checked out elsewhere has its own.

## As built (B-146, 2026-10-10)

The two open questions were decided as proposed: a refused `commit` leaves the session's
batch depth at zero, and the error says no batch is open; checkpoint names live in the
graph database. Where the code differs from the text above:

- **The journal's record is the node's own rows, not a tree entry.** A path is recorded
  as absent, as a file with its `output` and `fileMetadata` rows, or as a folder with its
  `pinned` and `symbolicLink` rows (`JournalRecord`). A `TreeManifestEntry` says what a
  file *is*; a replay has to put back what the graph *had*, including the states a tree
  has no word for — a name a formula asked for and nobody pushed, a removed source still
  wired, a folder nobody pinned — and a file link's bytes, which a tree entry does not
  carry. Rows written back as they were compare equal and wake nothing.
- **Where the rows live.** In the graph's `Metadata` table, `batchJournal/<session>/<path>`,
  written in the batch's own transaction. A server starting up drops every journal the
  process before it left: a batch it never committed stands as it was pushed, as before.
- **A refused batch still sends its one wake-up.** The engine counts the wake-ups a batch
  asks for, and `wait` tells a settled loop from one about to wake by that count; a
  wake-up held back for good left every later `wait` waiting. So the replay is followed by
  a flush that folds the folders back to what they held, and the pass the wake-up causes
  finds nothing to do — unless the batch's writes had already scheduled a consumer, which
  then reads what it read before and is answered from the cache.
- **The fold at `commit`** is the flush the next pass would have made, run inside a
  savepoint that a refusal rolls back, so a refused batch's roots are never published; on
  a re-vendor of GRDB.swift (771 files, 266 changed, 246 gone) the whole commit takes 117 ms
  in a debug build, against about a second for the push.
- **A lock folded under another format refuses the batch** (`otherFold`) rather than
  being compared: the barrier cannot say the folder matches, and a folder it cannot judge
  is locked shut, as one with an unreadable lock is.
- **Which folders, which paths.** A path's own lock is looked for too, so a lock edited
  alone is checked against its folder. The paths named are the batch's at or below the
  folder, and the lock's, whose rows the batch changed: a file pushed again unchanged and
  a folder made on the way to a file are left out. Only the first refused folder, in path
  order, is named.
- **The watcher.** A change to a lock mirrors its folder and pushes it in the lock's batch,
  which is how a re-vendor lands while the folder itself is not watched; the initial
  mirror leaves locked folders alone, so a copy edited by hand while no watcher ran does
  not have the whole launch refused.
- **`build`** stops after a refused push: nothing has changed to wait for, and it says
  `Not built: the push was refused, and nothing was exported.`
- **The reply** is an `ErrorResponse` case, since `commit` fails: every client already
  prints an `ErrorResponse`, and the refusal is the request's own failure, not an answer.
  The error report's `ErrorCondition` was not on main when this was built, so the refusal
  is its own typed case, rendered in that report's shape — a statement, then `lock:`,
  `expected:`, `found:` and `paths:` lines; when the two meet, it becomes a condition.
- **The end-to-end case** gives `swift-binary-target-app`'s `Greeting` a dependency on a
  repository the test makes, which `prepare` vendors and locks; the dependency is declared
  and not imported, since an Xcode project's local package has its remote dependencies
  vendored but not yet built against by the project's converter. The barrier is at the
  push, whatever reads the folder.
