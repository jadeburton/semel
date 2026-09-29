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
        ///
        /// `overlay` names a folder under `EndToEnd/Fixtures` — `"external/lua"` — laid
        /// over the subfolder once the checkout is copied, each file at its path
        /// (`EndToEndRun.lay`). It is one of two things. For a project with no `platform`,
        /// the formula and the project config of a project that has no converter to write
        /// them (B-76): only `prepare` writes into a clone otherwise, and a C project has
        /// no `prepare`. Such a formula reads the machine's settings from
        /// `../semel.machine.config`, as the C fixtures do, and the harness writes that
        /// file beside the subfolder for it, as it does for a fixture. For a project with a
        /// `platform`, corrected copies of the checkout's own files, each replacing the
        /// file at its path, because `prepare` writes the formula and the configs and the
        /// sample does not compile as it stands (`food-truck-mac`, B-77).
        case git(url: String, commit: String, subfolder: String, overlay: String? = nil)
        /// This repository's own checkout, as it is on disk: Semel building Semel (B-78).
        /// What is not the build stays out of the copy — build products, version control,
        /// the end-to-end fixtures, which are projects of their own with formulas the
        /// finder would otherwise build too, and anything a developer's in-place `prepare`
        /// left behind. Nested one level under base, named after `name`, for the reason a
        /// `.git` checkout with `subfolder: "."` is; `buildFolder` must equal `name`.
        case repository
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
    /// For `semel-swift prepare --application`: the application target to build, for a
    /// project with more than one for the platform (B-77); nil lets the platform pick.
    var application: String?
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
    /// When set, every exported file lies under this folder: an app's build root holds the
    /// app, and not the archives of the packages it links (B-67).
    var onlyUnder: String?
    /// Expected products that must be exported executable, mode 0755: a linked program on
    /// its own, or one inside a bundle tree, which carries the mode per entry (B-108).
    var executables: [String] = []
    /// Run over the build folder of the materialised copy, before `configure`: what a
    /// fixture needs that the repository does not hold — a binary framework built on this
    /// machine, as a vendor would ship it (B-77). Every build, the second mount's too, sees
    /// what it made.
    var materialised: ((URL) throws -> Void)?
    /// Run over each export once its products are checked: what a list of files cannot
    /// say — what the linked executable loads, and that it runs.
    var exported: ((URL) throws -> Void)?
}

extension Project.Source {

    /// The fixtures folder laid over a `.git` checkout, when the source has one.
    var overlay: String? {
        guard case .git(_, _, _, let overlay) = self else {
            return nil
        }
        return overlay
    }
}
