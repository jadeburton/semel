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
        /// the build folder is relative to. The base of the run is the copy of the
        /// subfolder's parent, so a tree of packages builds with `Dependencies` beside it.
        /// `"."` means the checkout's own root holds what `buildFolder` names; since a
        /// build folder cannot be the base itself, the checkout is nested one level under
        /// base instead, named after `name` — so `buildFolder` must equal `name`.
        case git(url: String, commit: String, subfolder: String)
    }

    let name: String
    let source: Source
    /// The argument to `build`, relative to the base.
    let buildFolder: String
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
    /// Whether the run builds a third time from a copy at a mount whose name has a
    /// different length, and requires that export to match the first. False only for a
    /// project whose build is too long to run three times.
    var twoMounts: Bool = true
    /// Whether the run builds once more with the environment and the working directory
    /// perturbed (`Perturbation`), and requires that export to match the first. False
    /// only for a project whose build is too long to run again.
    var perturbed: Bool = true
}
