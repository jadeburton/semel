# Symbolic links from a push to an export (B-77 item 2, B-26, B-06)

Status: design and as built, 2026-09-29. B-77 item 2's map item 1 left one thing: a
versioned framework — Sparkle's, the fixture's `Tiny.framework` — arrived in a bundle with
`Versions/Current` and every link at its top as copies, because a push followed a link, the
disk fold did the same, and a tree had no entry for one. `codesign` calls such a framework
ambiguous, so `CodeSigner` laid the copies back as links in its sandbox and handed copies
on again, and the export did not verify. This carries the link itself, from the push to the
export.

## Which links are links

A symbolic link met by a push is pushed as a link — its target, relative, as the link
holds it — when the target, read from the link's own folder, **stays inside that folder**:
it is relative, it never climbs above the link's folder with `..`, it names no dot-named
component (which a push leaves out, so the link would name nothing pushed), and it names
something below the folder rather than the folder itself
(`ExternalFileSystemLister.isContained(symbolicLinkTarget:)`). Every link a bundle holds is
of this kind — `Versions/Current -> A`, `Tiny -> Versions/Current/Tiny`,
`Headers -> Versions/Current/Headers` — and so is a library's `libz.dylib -> libz.1.dylib`.

Every other link keeps today's behaviour, and says which:

- a link to a folder above it (a cycle) is refused — left out, as the IceCubes fix made it;
- a link to nothing — dangling, or a loop — is left out, as a missing file is;
- any other link, absolute or climbing out of its folder, is followed: a file's bytes are
  pushed under the link's name, a folder is walked, and nothing says it was a link. A C
  package's `include/foo.h -> ../foo.h` is the common case.

The rule is about the link's own folder and not about the folder the push was asked for,
on purpose. `prepare` folds a vendored package on disk rooted at `Dependencies/Sparkle`; the
engine folds the same folder inside a push of the whole clone. A rule reading "inside the
pushed folder" would make a link to `../../Shared` a link to the engine and a copy to
`prepare`, and the lock would never match. A link that stays inside its own folder stays
inside every folder that holds it, so both folds decide it the same way from any root —
and it is inside whatever folder was pushed, which is what the entry asked for.

## A link is what a push always stored, plus what it holds

The lister still lists a link as the file or folder it names, walked as one, and says what
the link holds beside it: `FileWildcardEntry.symbolicLinkTarget`. The push stores what it
always stored — a link to a file as a `StaticFile` holding the file's bytes, a link to a
folder as a `Folder` holding what is in it — and records the target:

- a **file** link's target is on its `fileMetadata`, beside the mode:
  `FileMetadata.symbolicLinkTarget`;
- a **folder** link's target is on a new `Folder` port, `symbolicLink` (the empty value for
  a folder that is not a link), and its parent's manifest lists it:
  `FolderManifestEntry.symbolicLinkTarget`.

So every consumer that reads a file's bytes or walks a folder reads what it read before.
That matters beyond headers: RevenueCat, which IceCubes vendors, keeps two targets' sources
behind folder links to siblings (`CustomEntitlementComputation -> Sources`,
`LocalReceiptParsing -> Sources/LocalReceiptParsing`), which SwiftPM follows, and a folder
link that the graph did not walk through would have taken them away from the converter.
What reads the target is exactly what carries a tree's shape: the fold, a walk building a
tree, a product, and the export.

The alternatives, and why not:

- *A link as a node of its own.* A link is a file or a folder in every manifest, and every
  consumer that lists a folder and demands `StaticFile(path:)` or `Folder(path:)` for what
  it finds would make a second node beside the link: a name collision.
- *A link as a file holding its target, git's model.* Clean for trees and folds, but what
  reads a file through its port reads the path text instead of the bytes, and a walk stops
  at a folder link. Every consumer would have to learn links.

The bytes a file link holds are a copy taken at push time, so a push of the target alone
leaves them as they were. That was already so — the copy a push made under the link's name
went stale the same way — and a push of the folder, which every `build` makes, refreshes
both. A push only adds, so a link on disk replaced by a folder stays a link in the graph
until it is removed, as a file removed from disk stays a file.

## The wire

`DaemonRequest.pushSymbolicLink(path:target:referent:)`, the referent
`SymbolicLinkReferent.file(mode:)` — the file's bytes in the frame body — or `.folder`,
whose files arrive as pushes of their own, below the link's path. Answered by
`pushFile(didChange:)`. The push sends a folder link although it sends no other subfolder,
since a push makes folders only on the way to files and a link is more than that. A
`fetch` of a link answers `DaemonResponse.symbolicLink(target:)` with no body, which is
what `cp` and `export` write. `ProtocolVersion` 19. The client and `prepare` are the two
writers, both through the lister.

## The fold

`FolderContentRoot` gains a line kind, `link`, whose content is the target:
`link\ttarget <bytes> <target>\t<name bytes>\t<name>` — the target framed by its length as
the name is, so a tab or a newline in one changes the root and not the document's shape.
Nothing is read through a link: what it names is folded where it is. A file link removed
is `link\tdeleted\t…` — the kind from the metadata a removal keeps, the state from the
bytes' port. The format tag moves to `semel-folder-content-root 3`, so a lock written
under 2 is "cannot be compared", as designed (B-06), and `prepare` writes 3.

The engine's fold reads the file children's metadata and the folder children's
`symbolicLink` in one query each, and resolves each distinct document once — a folder of
three thousand files holds a handful. A `StaticFile` whose metadata changes marks its
folder, as one whose bytes change does, and so does a folder that becomes a link.

## Trees

`TreeManifestEntry` holds a path and its content: `.file(hash:mode:)` as before, or
`.symbolicLink(target:)`. Spelled out in the encoding as the mode was: a file is
`{"hash","mode","path"}`, exactly as before, so a tree without links interns to the hash it
always did; a link is `{"path","symbolicLink"}`.

**A tree holds only links that resolve inside it.** A link entry's target, followed from its
place — through other links, `..` taken where the walk stands — names a file or a folder of
the same tree (`TreeManifest.resolve`). Builders keep it so: `TreeManifest(placing:folderLinks:)`
takes each file a builder read with its metadata, and each folder link a walk met, keeps a
link where it resolves among what is placed, and otherwise places a file link as the bytes
and mode it carries — the copy a push made before this — and leaves a folder link out, its
folder holding nothing a push would push. Placing a tree under a folder and merging trees
keep every link resolving, so `TreeMerge` only adds collisions: one link twice is one
entry; a link and a file at one path, or a path below a link, are two trees disagreeing.

- `TreeBuilder` places what arrives on its wires; `FolderTreeBuilder` and
  `XCFrameworkSliceSelector` walk with `FolderTreeWalk.subfolderSpecs(…, intoSymbolicLinks:
  false)` — never into a folder link, whose copy is walked where it really is — and place
  the folder links their manifests list.
- `TreeFile` puts a link entry on its ports as a pushed link is: the target on
  `fileMetadata`, what it names in the tree on `output` — a file's bytes and mode, or the
  empty file for a folder.
- A tool is handed a link entry as a link (`FileNameAndContent(symbolicLinkAt:target:)`, laid
  by `LocalFileSystemTool`), and a link a tool leaves in an expected output folder comes back
  as a link entry (`ToolOutput.writeTreeLink`), where it was skipped: what `codesign` signs is
  handed back with its links. `SimplifiedToolExecuteResult.outputTrees` holds tree entries.
- `TreeManifest.inputFiles` and `mergedInputFiles` lay links, so a compiler's `-F` and a
  linker's `-framework` see the framework the vendor built.

## Out of the graph

- The export and `cp` write a link, replacing whatever an earlier export left at the path
  without following it — a folder of copies included — and set no mode on it.
- The settle diff treats a link as an entry: an artifact's reported hash is, for a link,
  its metadata document's — which holds the target — so retargeting a link is a change, and
  so is a link standing where a file with the same bytes was.
- The collector keeps the objects a tree names by hash; a link names none.
- `CodeSigner` lays the tree as it is and signs the real thing; `SigningLayout`'s
  recognition of copies as links, and its restoring of copies, are gone.

## Versions

`FolderContentRoot.formatTag` 3; `ProtocolVersion` 19; `Semel.version` 0.1.13, because
every preserved folder needs a row for the new port and a root folded under the new tag.
No table changes, so no schema fingerprint moves. Every node whose output changes is
bumped: `TreeBuilder` 2, `FolderTreeBuilder` 3, `TreeMerger` 3, `TreeFile` 2,
`XCFrameworkSliceSelector` 2, `CodeSigner` 2. A node only reading a tree needs nothing: the
tree it reads is a new value. A tool node filling a tree from an output folder
(`AssetCatalogCompiler`, `IBToolCompiler`, the string catalog compiler) is not bumped: its
tools write no links, and a tree of files encodes as it did.

What a stored graph pushed as a copy of a link becomes the link at the next push — a
folder copy gains its `symbolicLink`, a file copy its target — so an old home needs no
more than the push every `build` makes.
