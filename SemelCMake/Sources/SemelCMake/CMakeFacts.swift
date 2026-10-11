//
//  CMakeFacts.swift
//  SemelCMake
//
//  What evaluation is told about the build it translates for, as values: the variables
//  CMake would set from the platform before reading a file, and where the project is.
//  A value rather than a machine read, so that what `if(APPLE)` decided is a parameter of
//  the translation — the same files and the same facts give the same model anywhere, which
//  is what a node needs and what a test holds the evaluator to.
//

public struct CMakeFacts: Equatable {
    /// Where the project root is, as `CMAKE_SOURCE_DIR` says it: the folder's real path
    /// under `semel-cmake`, and `input:/<folder>` under a node. The evaluator keeps every
    /// path relative to it, and a path under this prefix comes back as one.
    public var sourceDirectory: String
    /// Set before the root file is read, as the platform's constants: `APPLE`, `UNIX`,
    /// `CMAKE_SYSTEM_NAME` and the compiler's identity. A file's own `set` overrides one.
    public var variables: [String: String]

    public init(sourceDirectory: String, variables: [String: String]) {
        self.sourceDirectory = sourceDirectory
        self.variables       = variables
    }

    /// A Mac with Apple's clang, building Debug: what the toolchain here is. `WIN32`,
    /// `MSVC` and `BUILD_SHARED_LIBS` are left unset, which reads as false.
    public static func macOS(sourceDirectory: String) -> CMakeFacts {
        CMakeFacts(sourceDirectory: sourceDirectory, variables: [
            "APPLE":                   "1",
            "UNIX":                    "1",
            "CMAKE_HOST_APPLE":        "1",
            "CMAKE_HOST_UNIX":         "1",
            "CMAKE_SYSTEM_NAME":       "Darwin",
            "CMAKE_HOST_SYSTEM_NAME":  "Darwin",
            "CMAKE_SYSTEM_PROCESSOR":  "arm64",
            "CMAKE_C_COMPILER_ID":     "AppleClang",
            "CMAKE_CXX_COMPILER_ID":   "AppleClang",
            "CMAKE_BUILD_TYPE":        "Debug",
        ])
    }
}
