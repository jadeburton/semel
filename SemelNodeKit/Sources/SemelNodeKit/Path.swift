// Path.swift
// semel
//
// A type-safe representation of an internal (virtual) file path.
// Internal paths are slash-separated sequences of name segments, e.g.
//   "input:/src/hello.c"  →  Path([Folder.inputFileSystemName, "src", "hello.c"])
//
// Path is *not* used for real filesystem paths — those remain as String/URL so
// that Foundation APIs (FileManager, NSString, URL) can be used directly.

// MARK: - Path

public struct Path {

    // MARK: Core storage

    /// The individual path segments, e.g. [Folder.inputFileSystemName, "src", "hello.c"].
    /// Never contains empty strings or slashes.
    public let segments: [String]

    // MARK: Constants

    public static let empty = Path(segments: [])

    // MARK: Init

    public init(segments: [String]) {
        self.segments = segments.filter { !$0.isEmpty }
    }

    /// Parse a slash-delimited string into a Path.
    /// Leading/trailing slashes and empty segments are silently ignored.
    public init(_ string: String) {
        self.init(segments: string
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init))
    }

    // MARK: Properties

    public var isEmpty: Bool { segments.isEmpty }
    public var count: Int    { segments.count }

    /// The last segment, e.g. "hello.c".
    public var lastComponent: String? { segments.last }

    /// The first segment, e.g. Folder.inputFileSystemName.
    public var firstComponent: String? { segments.first }

    /// Path with the last segment removed.  Returns `nil` for single-segment or empty paths.
    public var deletingLastComponent: Path? {
        guard segments.count > 1 else {
            return nil
        }
        return Path(segments: Array(segments.dropLast()))
    }

    /// Path with the first segment removed.  Returns `nil` for single-segment or empty paths.
    public var deletingFirstComponent: Path? {
        guard segments.count > 1 else {
            return nil
        }
        return Path(segments: Array(segments.dropFirst()))
    }

    /// Whether any segment contains a `*` or `?` wildcard character.
    public var containsWildcard: Bool {
        segments.contains { $0.contains("*") || $0.contains("?") }
    }

    /// Slash-joined string representation, e.g. "input:/src/hello.c".
    public var string: String { segments.joined(separator: "/") }

    // MARK: Combining paths

    /// Returns a new Path with `component` appended as a new segment.
    public func appending(_ component: String) -> Path {
        Path(segments: segments + [component])
    }

    /// Returns a new Path with all segments of `other` appended.
    public func appending(_ other: Path) -> Path {
        Path(segments: segments + other.segments)
    }

    // MARK: Prefix / relative

    /// Returns `true` when this path starts with all segments of `prefix`.
    public func hasPrefix(_ prefix: Path) -> Bool {
        guard segments.count >= prefix.segments.count else {
            return false
        }
        return Array(segments.prefix(prefix.segments.count)) == prefix.segments
    }

    /// Returns the portion of this path after `base`, or `nil` if `base` is not a prefix.
    /// e.g. Path("input:/src/hello.c").relative(to: Path(Folder.inputFileSystemName)) → Path("src/hello.c")
    public func relative(to base: Path) -> Path? {
        guard hasPrefix(base) else {
            return nil
        }
        return Path(segments: Array(segments.dropFirst(base.segments.count)))
    }

    // MARK: Dot segments

    /// This path with each `.` segment dropped and each `..` taking away the segment
    /// before it, or nil when a `..` would take away the first segment. The first segment
    /// of an internal path is its file system's name (`input:`), so a path that climbs
    /// above it names nothing in any file system — and resolving it anyway would read
    /// `input:/../output:/x` as `output:/x`.
    public var resolvingDotSegments: Path? {
        var resolved: [String] = []
        for segment in segments {
            switch segment {
            case ".":
                continue
            case "..":
                guard resolved.count > 1 else {
                    return nil
                }
                resolved.removeLast()
            default:
                resolved.append(segment)
            }
        }
        return Path(segments: resolved)
    }

    // MARK: Subscript

    public subscript(index: Int) -> String { segments[index] }
}

// MARK: - Operators

extension Path {
    /// Append a single component: `path / "hello.c"` → `path.appending("hello.c")`
    public static func / (lhs: Path, rhs: String) -> Path { lhs.appending(rhs) }

    /// Append another path: `base / sub` → `base.appending(sub)`
    public static func / (lhs: Path, rhs: Path) -> Path { lhs.appending(rhs) }
}

// MARK: - Protocol conformances

extension Path: Equatable {}
extension Path: Hashable {}

extension Path: CustomStringConvertible {
    public var description: String { string }
}

extension Path: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

extension Path: Codable {
    // Encode/decode as a plain slash-delimited string for readability in JSON/DB.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
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
