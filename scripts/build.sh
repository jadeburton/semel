#!/bin/sh
#
# `swift build` and `swift test` with SwiftPM's build-plan cache switched off.
#
# SwiftPM writes the build plan to `.build/debug.yaml` and re-plans only when llbuild's
# `PackageStructure` command is dirty. That command's inputs come from `BuildPlan.inputs`,
# which iterates `graph.rootPackages`: the *root* package's target directories, its
# `Package.swift` and its `Package.resolved`, and nothing else. Every package in this
# repository except the one being built is a path dependency, so a source file added to or
# removed from `SemelNodeKit`, `SemelCore`, `SemelProtocol`, `SemelSwift`, `SemelClang`,
# `SemelApple`, `SemelDatabaseModels` or `SemelExamples` is an input to nothing. The plan
# stays as it was: an added file is never compiled, and the first thing that names it fails
# with `cannot find 'X' in scope`; a removed file is still demanded, and the build fails
# with `missing inputs: …/X.swift` while the previous binary stays linked.
#
# `--disable-build-manifest-caching` plans on every invocation. On this package that costs
# under a tenth of a second, which buys a build that reads the tree instead of a snapshot
# of it.
#
# Usage:
#   scripts/build.sh                                  # swift build
#   scripts/build.sh -c release                       # swift build -c release
#   scripts/build.sh test                             # swift test, root package
#   scripts/build.sh test --package-path SemelCore    # swift test in one package

set -eu

case "${1-}" in
    build | test | run)
        verb="$1"
        shift
        ;;
    *)
        verb=build
        ;;
esac

exec swift "$verb" --disable-build-manifest-caching "$@"
