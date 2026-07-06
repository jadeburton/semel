// Path.swift
// build_system
//
// A type-safe representation of an internal (virtual) file path.
// Internal paths are slash-separated sequences of name segments, e.g.
//   "inputFileSystem/src/hello.c"  →  Path(["inputFileSystem", "src", "hello.c"])
//
// Path is *not* used for real filesystem paths — those remain as String/URL so
// that Foundation APIs (FileManager, NSString, URL) can be used directly.

// MARK: - Path

struct Path {

    // MARK: Core storage

    /// The individual path segments, e.g. ["inputFileSystem", "src", "hello.c"].
    /// Never contains empty strings or slashes.
    let segments: [String]

    // MARK: Constants

    static let empty = Path(segments: [])

    // MARK: Init

    init(segments: [String]) {
        self.segments = segments.filter { !$0.isEmpty }
    }

    /// Parse a slash-delimited string into a Path.
    /// Leading/trailing slashes and empty segments are silently ignored.
    init(_ string: String) {
        self.init(segments: string
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init))
    }

    // MARK: Properties

    var isEmpty: Bool { segments.isEmpty }
    var count: Int    { segments.count }

    /// The last segment, e.g. "hello.c".
    var lastComponent: String? { segments.last }

    /// The first segment, e.g. "inputFileSystem".
    var firstComponent: String? { segments.first }

    /// Path with the last segment removed.  Returns `nil` for single-segment or empty paths.
    var deletingLastComponent: Path? {
        guard segments.count > 1 else { return nil }
        return Path(segments: Array(segments.dropLast()))
    }

    /// Path with the first segment removed.  Returns `nil` for single-segment or empty paths.
    var deletingFirstComponent: Path? {
        guard segments.count > 1 else { return nil }
        return Path(segments: Array(segments.dropFirst()))
    }

    /// Whether any segment contains a `*` or `?` wildcard character.
    var containsWildcard: Bool {
        segments.contains { $0.contains("*") || $0.contains("?") }
    }

    /// Slash-joined string representation, e.g. "inputFileSystem/src/hello.c".
    var string: String { segments.joined(separator: "/") }

    // MARK: Combining paths

    /// Returns a new Path with `component` appended as a new segment.
    func appending(_ component: String) -> Path {
        Path(segments: segments + [component])
    }

    /// Returns a new Path with all segments of `other` appended.
    func appending(_ other: Path) -> Path {
        Path(segments: segments + other.segments)
    }

    // MARK: Prefix / relative

    /// Returns `true` when this path starts with all segments of `prefix`.
    func hasPrefix(_ prefix: Path) -> Bool {
        guard segments.count >= prefix.segments.count else { return false }
        return Array(segments.prefix(prefix.segments.count)) == prefix.segments
    }

    /// Returns the portion of this path after `base`, or `nil` if `base` is not a prefix.
    /// e.g. Path("inputFileSystem/src/hello.c").relative(to: Path("inputFileSystem")) → Path("src/hello.c")
    func relative(to base: Path) -> Path? {
        guard hasPrefix(base) else { return nil }
        return Path(segments: Array(segments.dropFirst(base.segments.count)))
    }

    // MARK: Subscript

    subscript(index: Int) -> String { segments[index] }
}

// MARK: - Operators

extension Path {
    /// Append a single component: `path / "hello.c"` → `path.appending("hello.c")`
    static func / (lhs: Path, rhs: String) -> Path { lhs.appending(rhs) }

    /// Append another path: `base / sub` → `base.appending(sub)`
    static func / (lhs: Path, rhs: Path) -> Path { lhs.appending(rhs) }
}

// MARK: - Protocol conformances

extension Path: Equatable {}
extension Path: Hashable {}

extension Path: CustomStringConvertible {
    var description: String { string }
}

extension Path: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self.init(value) }
}

extension Path: Codable {
    // Encode/decode as a plain slash-delimited string for readability in JSON/DB.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

// MARK: - String ↔ Path bridge

extension String {
    /// Convert this slash-delimited string to an internal `Path`.
    var asPath: Path { Path(self) }
}

extension Path {
    /// Convert this path to a plain `String` for APIs that expect `String`.
    var asString: String { string }
}
