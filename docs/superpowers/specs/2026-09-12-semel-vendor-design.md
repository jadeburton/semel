# semel-vendor: every dependency's source inside the input file system

**Status:** design agreed 2026-09-12, implemented in the same change
**Relationship:** the mechanism B-10's formula design assumes for dependency overrides;
replaces the "vendored beside the package that named it" convention the converter used.

## The requirement

Semel is not a package manager, but it needs every file of every dependency to build a
project, and it must find them by a general rule rather than per-dependency configuration.
Until now a git dependency was expected *beside the package that declared it*
(`../GRDB.swift`), which made transitive dependencies land wherever their declarer sat,
duplicated diamonds, put a root package's dependencies outside the root, and left the
copying to hand-dragging.

## The rule

Every source-control or registry dependency of every package in a graph resolves to

    <root>/Dependencies/<name>

where `<root>` is the root package's folder in the input file system and `<name>` is the
repository's last path component minus `.git` for a git URL (`GRDB.swift`) or the
case-preserved identity for a registry package (`mona.LinkedList`). The rule is applied
relative to the root, not to the declaring package, at every depth.

Why flat and why the root: SwiftPM guarantees one identity per package graph, so a flat
directory cannot collide and a diamond dependency is one copy. It is also SwiftPM's own
checkout layout, which makes the tool a copy loop.

Local path dependencies (`.package(path:)`) are untouched: the manifest states their path,
they are pushed like any other source, and the existing sibling arrangement (`MyApp`
consuming `../MyLibrary`) keeps working.

## The tool

`semel-vendor <package-root>` runs `swift package resolve` on the root package — SwiftPM
does versions, `Package.resolved` pinning, branches, registries and transitive resolution;
Semel re-implements none of it — then copies every checkout under `.build/checkouts` into
`<package-root>/Dependencies/<name>`, replacing what is there, skipping `.git` and `.build`
inside each checkout. It prints what it copied. It writes nothing Semel reads beyond the
source trees; the rule above is the whole contract. Needs a toolchain and network on the
vendoring machine, which is fine for a tool outside Semel.

Registry packages are not copied yet: `swift package resolve` places them under
`.build/registry/downloads/<scope>/<name>/<version>`, and no project in front of us uses
one. The converter already resolves them to `Dependencies/<scope.name>`; the tool's copy
step is a small addition when needed.

## What changes in Semel

`SwiftFormulaConverter`: source-control and registry dependencies resolve to
`<root>/Dependencies/<name>`; the stall message names the tool. Local path dependencies
resolve as before. Tests pin both.

## Later

- A `.semel-lock` per copy with origin and revision from `Package.resolved` gives B-06
  its data; the tool has it in hand.
- B-10's formula may declare a URL-to-path override; the rule here is the default it
  overrides.
