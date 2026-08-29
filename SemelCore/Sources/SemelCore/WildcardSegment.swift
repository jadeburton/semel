// WildcardSegment.swift
// SemelCore
//
// Matching one path segment against a pattern containing `*` and `?`.
//
// Standalone, and static, because two unrelated things need it: FileWildcardMatcher, which
// walks a real directory tree, and ProjectBuilder, which globs over a folder manifest that
// has already arrived on a wire. Neither can reach the other's internals, so the second was
// written as a copy of the first — and the copy is how one of them came to be rewritten for
// legibility while the other stayed as it was.

enum WildcardSegment {

    /// Whether `name` matches `pattern`, where `?` stands for any one character and `*` for
    /// any run of them.
    ///
    /// A segment, not a path: neither wildcard crosses a `/`, because both callers have
    /// already split the path and are asking about one component.
    static func matches(pattern: String, name: String) -> Bool {
        matches(pattern: Array(pattern.unicodeScalars),
                name:    Array(name.unicodeScalars))
    }

    /// Walks both strings once, remembering the most recent `*` so it can come back to it.
    /// When the rest of the pattern hits a dead end, that `*` is given one more character and
    /// the walk resumes — which is what makes `*.swift` match `a.b.swift`, where the first
    /// attempt commits the `*` to the wrong dot.
    ///
    /// Only the most recent `*` needs remembering. An earlier one can always hand its work to
    /// a later one, so backtracking further can never find a match this one could not.
    private static func matches(pattern: [Unicode.Scalar], name: [Unicode.Scalar]) -> Bool {
        var patternIndex = 0
        var nameIndex    = 0

        // Where to resume when an attempt fails: the pattern position just after the most
        // recent `*`, and how much of the name that `*` has been given so far. Nil until a
        // `*` has been seen, which is what makes a mismatch final rather than retried.
        var afterLastStar:  Int? = nil
        var nameAtLastStar: Int  = 0

        while nameIndex < name.count {
            if patternIndex < pattern.count,
               pattern[patternIndex] == "?" || pattern[patternIndex] == name[nameIndex] {
                patternIndex += 1
                nameIndex    += 1

            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                // Start by letting this `*` match nothing, and note where to come back to.
                afterLastStar  = patternIndex + 1
                nameAtLastStar = nameIndex
                patternIndex  += 1

            } else if let afterLastStar {
                // Dead end — give the most recent `*` one more character and resume after it.
                nameAtLastStar += 1
                nameIndex       = nameAtLastStar
                patternIndex    = afterLastStar

            } else {
                return false        // mismatch, and no `*` to fall back on
            }
        }

        // The name is used up; the pattern matches only if what is left of it is all `*`.
        return pattern[patternIndex...].allSatisfy { $0 == "*" }
    }
}
