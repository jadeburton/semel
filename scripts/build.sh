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
# about 0.15 s of planning, inside the noise of process start-up, and it buys a build that
# reads the tree instead of a snapshot of it. A cold build plans anyway, so the flag is
# inert there; it earns its keep on the incremental builds in an edited tree.
#
# Usage:
#   scripts/build.sh                                  # swift build
#   scripts/build.sh -c release                       # swift build -c release
#   scripts/build.sh test                             # swift test, root package
#   scripts/build.sh test --package-path SemelCore    # swift test in one package
#   scripts/build.sh run semel --help                 # swift run

set -eu

case "${1-}" in
    build | test | run)
        verb="$1"
        shift
        ;;
    "" | -*)
        # No verb, or the first word is a flag for `swift build`.
        verb=build
        ;;
    *)
        # Anything else is a word this script would silently feed to `swift build` as a
        # positional argument, where ArgumentParser rejects it with a message that names
        # neither the script nor the mistake.
        printf 'scripts/build.sh: unknown verb: %s\n' "$1" >&2
        printf 'usage: scripts/build.sh [build|test|run] [swift arguments]\n' >&2
        exit 2
        ;;
esac

exec swift "$verb" --disable-build-manifest-caching "$@"
