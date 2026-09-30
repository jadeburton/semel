# A push that sends only what the server lacks (B-132)

Status: design and as built, 2026-09-30. After B-131 an unchanged push of the IceCubes app
tree — 8,039 files — cost 5.0 s: one request per file, each carrying the file's bytes, each
answered by one select that found the file already held. Against `xcodebuild` that push is
the whole of Semel's loss on the app-level one-file edit (BACKLOG, Performance, 2026-09-29).
This makes a push of a folder compare first and send only where the disk and the server
differ.

## The comparison

The engine already publishes, for every folder, a Merkle root over what it holds
(`Folder.contentRoot`, `FolderContentRoot`), and `prepare` already folds a folder on disk to
the root the engine will publish for the pushed copy (B-06). A push of a folder:

1. **Folds the disk.** `FolderOnDisk` walks the folder with the lister `push` has always
   used — dot-names left out, a link inside its own folder kept as the link, any other link
   followed, a folder with nothing to push left out, the build's export folder left out —
   and folds each folder with `FolderContentRoot.document(of:)`, hashing each file by
   `Sha256.hash`, the rule the object store names objects by (32 bytes or less is its own
   bytes), so a hash on disk and a hash in the graph compare. A folder link is walked too:
   what the link names is stored below the link's path as a copy, and that copy has a
   `Folder` of its own whose root is compared like any other. `FolderContentRoot.root(ofFolderAt:)`
   — `prepare`'s — is now this walk's top root, so a lock and a push cannot disagree.
2. **Asks for the roots.** `contentRoots(path:)` answers, in one request, the root of the
   folder and of every folder below it, with whether each is pinned. Two queries on the
   server however large the tree: the folder's path (`selectPath`), then the subtree with
   both ports (`selectSubtree`, one recursive query). The subtree walk steps from a folder
   to its subfolders by a new index on `Node(parentNodeID, kind)`, and its joins are
   `CROSS JOIN`s so SQLite keeps the subtree outermost: left to the planner, the first
   measurement walked each step by the index on `kind` alone and scanned `Node` for the
   rest — 0.4 s on the IceCubes tree, against 2 ms. An existing database gains the index
   on open, as it gained B-131's.
3. **Compares top down.** A folder the server holds pinned under the same root is held, file
   for file, and nothing below it is sent or asked about. A folder the server lacks is sent
   whole, as every push did before. A folder whose root differs — or whose root the server
   will not vouch for, below — is compared child by child, and its subfolders by their own
   roots.
4. **Asks for the children of the folders that differ.** `folderChildren(paths:)`, one
   request for all of them, answers each child's name, kind, content hash, mode, link
   target and pin. A file is sent when its hash, mode or link target differs or the server
   lacks it; a folder link when its target differs or the server lacks it; an unpinned
   folder is pushed to pin it, as a push always leaves folders pinned.
5. **Sends the rest as before**: `pushFile`, `pushSymbolicLink`, `pushFolder`, their
   `didChange` answers, one batch around them.

With the requests gone, what an unchanged push costs is the client reading the disk: every
file opened and hashed. The walk lists first and reads after, the files on every core
(`DispatchQueue.concurrentPerform`), and the lister and the mode ask `lstat` and `stat`
directly rather than through `FileManager`'s attribute dictionaries — together a 2.1 s push
of the IceCubes tree became 0.6 s. A cache of each file's hash by its size and
modification time, as git's index keeps, would take most of the rest; it is not built,
because a hash taken from a stale cache entry is a push that silently sends nothing.

The report is the one a push always printed: every file below the folder is counted, and
one the push did not send is counted as unchanged — it is, and the server would have said
so. A file that is not sent is not read twice: the fold read it once to hash it, and a
link's bytes are read only where its folder's root already differs.

### A file's mode is on the root

A root that did not move with a file's mode would call two trees one: `chmod +x` on a script
would never be sent. The mode has always been part of a tree (`TreeManifest`) and of what a
push stores (`FileMetadata`), but the fold left it out ("a mode change folds to the same
root again"). A file's line now carries it — `file\thash <h> mode 755\t…` — under
`semel-folder-content-root 4`, and the engine reads the mode from the same metadata
documents it already resolved for links, so the fold costs no extra query. A lock written
under 3 reads as "cannot be compared", as designed (B-06), and `prepare` writes 4.
`Semel.version` 0.1.14, because every preserved folder holds a root folded under 3.

### A root that is waiting to be folded is not offered

A push marks the folder it wrote into, and the engine folds the root later, walking up one
level per round (B-25, B-26). Between a push and that fold, a folder's root describes what
it held before: exactly what the disk holds again if the user put a file back. So the
answer to `contentRoots` reads the marks in the same snapshot as the roots, and a marked
folder and every folder above it answer no root; the client compares their children
instead. For that to be enough, a fold clears its mark and marks the folder above in one
transaction (`Folder.refreshMarkedContentRoot`), so no reader sees the one without the
other. `ManifestPushScaleTests.test_aPushBeforeTheLastIsFoldedStillSendsWhatDiffers` pins
it, and fails without the marks.

## `push` stays additive

A file the server holds and the disk does not — deleted, or its folder emptied — is not
removed: `push` has only ever added, and a build goes on reading it. What changes is that
the push now knows, because it compared, and says so: `Not on disk, kept: src/old.c (push
only adds; rm removes it)`, or a count when the push is too long to name paths. Only what a
push leaves is named — a file holding a value, a folder pinned — and never a name the graph
merely asks for (a ghost). A `--prune`, or `rm` driven by this list, is a later item.

## Costs, in requests

| push of a tree of N files in D folders | requests |
|---|---|
| fresh (the server holds nothing there) | 1 + N + the batch and the folder, as before |
| unchanged | 1 roots + 2 batch = 3, no bytes |
| one file edited | 1 roots + 1 children (the folders on its path) + 1 file + 2 batch |

`ManifestPushScaleTests` pins these for 400 files in 40 folders, with a mode change, a new
file and folder, a framework's links, a file gone from disk, and a push made before the
engine has folded the last. `HeldTreeTests` pins that the engine's roots are the disk's,
folder for folder, and that the roots cost two node selects however large the tree.

## What does not change

- The engine's `pushFile`, `pushFolder` and `pushSymbolicLink`, and their answers, for the
  files that are sent.
- A push of a file, or of a wildcard matching files, sends them as before; only a folder is
  compared. A folder matched inside one already compared is covered by it.
- `build`'s follow of missing sources, `begin`/`commit`, the progress line and the settle
  summary.
- `prepare`'s vendoring, which does not push.

What a push no longer does: mend a store that lost an object behind a file whose folder's
root agrees. B-131's push looked for each object on disk; this one does not look at a file
it does not send. A store that loses objects is damaged whatever pushes it; `rm` of the
folder and a push again send every file in it.

## Versions

`ProtocolVersion` 20 (`contentRoots`, `folderChildren` and their replies, whose records —
`HeldFolderRoot`, `HeldFolder`, `HeldChild` — travel as JSON in the reply body, as `check`'s
findings do, since the roots grow with the tree). `FolderContentRoot.formatTag` 4.
`Semel.version` 0.1.14. No node's output changes, so no `implementationVersion` moves; no
table changes, and the one new index is made on open.
