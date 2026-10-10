//
//  XcodeSearchPaths.swift
//  SemelApple
//
//  A target's search-path settings — `HEADER_SEARCH_PATHS`, `USER_HEADER_SEARCH_PATHS`,
//  `FRAMEWORK_SEARCH_PATHS` — as folders of the project (B-77 item 4). A folder of the
//  project is in the input file system, so the build can place what it holds; one outside
//  it — the SDK's, the developer folder's, a setting nothing defines — is not, and the
//  formula says which were left out rather than hand clang a path to a file nobody pushed.

import Foundation
import SemelNodeKit

struct XcodeSearchPaths: Equatable {

    /// One entry of a search-path setting that names a folder of the project.
    struct Entry: Equatable {
        /// Relative to the project's folder; empty for the folder itself.
        let path: String
        /// `path/**`: the folder and every folder below it, each a search path of its own,
        /// as Xcode expands a recursive entry.
        let isRecursive: Bool
    }

    /// `HEADER_SEARCH_PATHS`: an `-I` each.
    var headerSearchPaths: [Entry] = []
    /// `USER_HEADER_SEARCH_PATHS`: searched for a quoted include, and with
    /// `ALWAYS_SEARCH_USER_PATHS = YES` for an angle one too.
    var userHeaderSearchPaths: [Entry] = []
    /// `FRAMEWORK_SEARCH_PATHS`: where a framework is found by name, `-F` each.
    var frameworkSearchPaths: [Entry] = []
    /// The entries naming no folder of the project, as the setting spells them after
    /// evaluation: `/Applications/…/Library/Frameworks`, `$(PLATFORM_DIR)/…`.
    var outside: [String] = []

    init() {}

    init(settings: XcodeBuildSettings) {
        headerSearchPaths     = Self.entries(settings.list("HEADER_SEARCH_PATHS"), outside: &outside)
        userHeaderSearchPaths = Self.entries(settings.list("USER_HEADER_SEARCH_PATHS"), outside: &outside)
        frameworkSearchPaths  = Self.entries(settings.list("FRAMEWORK_SEARCH_PATHS"), outside: &outside)
    }

    /// Every folder of the project the settings name, recursive or not, each once, in the
    /// order first named: what the converter walks so the emitter knows what each holds.
    var folders: [Entry] {
        var seen: [Entry] = []
        for entry in headerSearchPaths + userHeaderSearchPaths + frameworkSearchPaths where !seen.contains(entry) {
            seen.append(entry)
        }
        return seen
    }

    /// The words of one setting as entries of the project: `$(SRCROOT)/include` and
    /// `include` alike are `include`, `$(SRCROOT)` is the project's folder, `/**` makes an
    /// entry recursive, and `$(inherited)` — what the levels below already said, which the
    /// evaluated setting has in its place where any level said something — is passed over.
    static func entries(_ words: [String], outside: inout [String]) -> [Entry] {
        var entries: [Entry] = []
        for word in words where word != "$(inherited)" && word != "${inherited}" && !word.isEmpty {
            var path = word
            var isRecursive = false
            if path.hasSuffix("/**") {
                path = String(path.dropLast("/**".count))
                isRecursive = true
            }
            if ["$(SRCROOT)", "${SRCROOT}", "$(PROJECT_DIR)", "${PROJECT_DIR}", "."].contains(path) {
                path = ""
            } else {
                path = XcodeFormulaEmitter.projectRelativePath(path)
            }
            while path.hasSuffix("/") {
                path.removeLast()
            }
            guard !path.hasPrefix("/"), !path.contains("$("), !path.contains("${"),
                  let resolved = path.isEmpty ? "" : Path(path).resolvingDotSegments?.string,
                  !resolved.hasPrefix("..") else {
                outside.append(word)
                continue
            }
            let entry = Entry(path: resolved, isRecursive: isRecursive)
            if !entries.contains(entry) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// The folders an entry stands for, relative to the project's folder: itself, and for a
    /// recursive one every folder below it that `listing` holds — its folders relative to
    /// the entry — in path order.
    static func expanded(_ entry: Entry, listing: XcodeFormulaEmitter.FolderListing?) -> [String] {
        guard entry.isRecursive else {
            return [entry.path]
        }
        let below = (listing?.folders ?? []).sorted().map { entry.path.isEmpty ? $0 : "\(entry.path)/\($0)" }
        return [entry.path] + below
    }
}
