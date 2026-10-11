//
//  CMakePaths.swift
//  SemelCMake
//
//  How a path in a CMake file becomes a path of the model: relative to the project root
//  where it is under it, and as given where it is not.
//

enum CMakePaths {

    /// `path` as a file names it, resolved against `folder` (relative to the root) and the
    /// root's own directory: a path under the root comes back relative to it, `.` and `..`
    /// folded; an absolute path elsewhere comes back as it is, and a relative one that
    /// climbs above the root keeps its leading `..`.
    static func resolve(_ path: String, inFolder folder: String, sourceDirectory: String) -> String {
        var text = path
        if text == sourceDirectory {
            return ""
        }
        if text.hasPrefix(sourceDirectory + "/") {
            text = String(text.dropFirst(sourceDirectory.count + 1))
            return normalized(text)
        }
        if text.hasPrefix("/") {
            return normalized(text, keepingLeadingSlash: true)
        }
        return normalized(folder.isEmpty ? text : folder + "/" + text)
    }

    /// `.` segments dropped and `..` folded into the segment before it where there is one.
    static func normalized(_ path: String, keepingLeadingSlash: Bool = false) -> String {
        var segments: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                if let last = segments.last, last != ".." {
                    segments.removeLast()
                } else {
                    segments.append("..")
                }
            default:
                segments.append(String(segment))
            }
        }
        let joined = segments.joined(separator: "/")
        return keepingLeadingSlash ? "/" + joined : joined
    }

    /// Whether the path is one of the project's: relative, and not climbing above the root.
    static func isInsideProject(_ path: String) -> Bool {
        !path.hasPrefix("/") && path != ".." && !path.hasPrefix("../")
    }

    /// The folder holding the path, empty for the root.
    static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else {
            return ""
        }
        return String(path[..<slash])
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }
}
