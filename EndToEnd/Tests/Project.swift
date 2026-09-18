//
//  Project.swift
//  SemelEndToEndTests
//
//  One project the harness builds: where it comes from, what to build, how to configure
//  it, and what must come out. Adding a project to the roster is adding one of these.
//

import Foundation

struct Project {

    enum Source {
        /// A folder under `EndToEnd/Fixtures`, `"."` for the whole tree. The base of the
        /// run is the copy of the whole `Fixtures` tree, whatever the folder.
        case fixture(folder: String)
        /// A repository at one commit; `subfolder` is the folder under the checkout that
        /// the build folder is relative to, `"."` for the checkout itself. The base of
        /// the run is the copy of the subfolder's parent, so a tree of packages builds
        /// with `Dependencies` beside it.
        case git(url: String, commit: String, subfolder: String)
    }

    let name: String
    let source: Source
    /// The argument to `build`, relative to the base.
    let buildFolder: String
    /// Folders pushed before the build, relative to the base: a path dependency that
    /// lives beside the build folder rather than under it.
    var alsoPush: [String] = []
    /// For `semel-swift prepare --platform`; nil means no prepare.
    let platform: String?
    /// Relative to the export directory; every one must exist and be non-empty.
    let expectedProducts: [String]
    let buildTimeout: TimeInterval
    /// Relative paths under the export directory, or path suffixes, whose bytes may differ
    /// between the two cold builds. Every other file must match. An entry names a
    /// difference a backlog item owns, with a comment saying which; the empty list is the
    /// rule.
    var mayDiffer: [String] = []
}
