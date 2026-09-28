// WildcardPath.swift
// SemelNodeKit
//
// Matching a path, segment by segment, against a pattern that may hold `**`.
//
// `WildcardSegment` answers for one name; this answers for a path below a folder, which is
// what a formula's `<src/**/*.c>` asks once `ProjectBuilder` has the folder manifests under
// `src`. It also answers the question the walk needs before it has them: whether a path
// below a given folder could match at all, so that only the folders a pattern can reach
// are demanded.

public enum WildcardPath {

    /// The segment that stands for any number of folders. Only a whole segment: `a**b` is
    /// two `*` in one name, which `WildcardSegment` reads as one.
    public static let anyFolders = "**"

    /// Whether `path` matches `pattern`, both split into segments.
    ///
    /// A `**` segment matches zero or more whole segments, so `**/*.c` matches `a.c` as
    /// well as `lib/a.c` and `lib/deep/a.c`, and a trailing `**` matches every path below
    /// the folder the pattern starts in. Any other segment matches exactly one segment,
    /// by `WildcardSegment`: `*` and `?` never cross a `/`.
    public static func matches(pattern: [String], path: [String]) -> Bool {
        alignment(pattern: pattern, path: path) != nil
    }

    /// Which segments of `path` each segment of `pattern` matched, or nil when it does not
    /// match: one range per pattern segment, a single segment for an ordinary one and any
    /// number, none included, for `**`.
    ///
    /// A capture reads this — the `*` in `**/*.c` captures from the last segment of the
    /// path, not from whichever segment the pattern's second segment would sit on without
    /// the `**`. Where two `**` could share folders differently, each takes as few as it
    /// can, so the answer is the same every time.
    public static func alignment(pattern: [String], path: [String]) -> [Range<Int>]? {
        align(pattern: pattern, patternIndex: 0, path: path, pathIndex: 0)
    }

    /// Whether some path strictly below `folder` could match `pattern`: the walk's
    /// question, asked of a folder before its manifest has been demanded. True when the
    /// pattern can consume `folder`'s segments and still has a segment left for what lies
    /// below, so `*.c` does not enter `lib`, `*/*.c` enters `lib` and not `lib/deep`, and
    /// `**/*.c` enters every folder.
    public static func canMatchBelow(pattern: [String], folder: [String]) -> Bool {
        reachesBelow(pattern: pattern, patternIndex: 0, folder: folder, folderIndex: 0)
    }

    // MARK: - Private

    private static func align(pattern: [String], patternIndex: Int,
                              path: [String], pathIndex: Int) -> [Range<Int>]? {
        guard patternIndex < pattern.count else {
            return pathIndex == path.count ? [] : nil
        }
        let segment = pattern[patternIndex]
        if segment == anyFolders {
            // Zero segments first, then one more at a time.
            var end = pathIndex
            while end <= path.count {
                if let rest = align(pattern: pattern, patternIndex: patternIndex + 1, path: path, pathIndex: end) {
                    return [pathIndex..<end] + rest
                }
                end += 1
            }
            return nil
        }
        guard pathIndex < path.count,
              WildcardSegment.matches(pattern: segment, name: path[pathIndex]),
              let rest = align(pattern: pattern, patternIndex: patternIndex + 1, path: path, pathIndex: pathIndex + 1) else {
            return nil
        }
        return [pathIndex..<(pathIndex + 1)] + rest
    }

    private static func reachesBelow(pattern: [String], patternIndex: Int,
                                     folder: [String], folderIndex: Int) -> Bool {
        guard folderIndex < folder.count else {
            // The folder is consumed; what lies below it has at least one more segment,
            // and any pattern segment left could take it.
            return patternIndex < pattern.count
        }
        guard patternIndex < pattern.count else {
            return false
        }
        let segment = pattern[patternIndex]
        if segment == anyFolders {
            return reachesBelow(pattern: pattern, patternIndex: patternIndex + 1, folder: folder, folderIndex: folderIndex)
                || reachesBelow(pattern: pattern, patternIndex: patternIndex, folder: folder, folderIndex: folderIndex + 1)
        }
        return WildcardSegment.matches(pattern: segment, name: folder[folderIndex])
            && reachesBelow(pattern: pattern, patternIndex: patternIndex + 1, folder: folder, folderIndex: folderIndex + 1)
    }
}
