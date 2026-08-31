// SemelSwift.swift
// SemelSwift
//
// What this package contributes, and how a host installs it.
//
// The engine has no idea these types exist. A composition root — the CLI, or a test —
// calls `register()` and from then on the graph can build Swift packages.

import SemelNodeKit

public enum SemelSwift {

    /// Installs this toolchain: its node types and the project kind it recognises.
    ///
    /// Idempotent, because a host may call it more than once and every test calls it again.
    public static func register() throws {
        try TypeRegistry.register(types: [
            SwiftCompilerTool.self,
            SwiftLinkerTool.self,
            SwiftPackageReaderTool.self,
            SwiftFormulaConverter.self,
        ])
        ProjectDiscovery.register(SwiftPackagePlugin())
    }
}

// MARK: - Project kind

/// Recognises a `Package.swift` and wires the reader and converter that turn it into a
/// formula the engine can build.
struct SwiftPackagePlugin: ProjectBuilderPlugin {
    func expectationString(forEntry entry: FolderManifestEntry, inFolder folderPath: String) -> String? {
        guard entry.isPinned, entry.name == "Package.swift" else { return nil }
        let fullPath      = (Path(folderPath) / entry.name).string
        let packageFolder = Path(fullPath).deletingLastComponent!.string

        // The reader shells out to a toolchain, so it needs the same `toolDescriptor` settings
        // every other tool does. This is the first node of every Swift build: wired to an
        // empty Configuration it fails before the manifest is ever read.
        let pkgReaderExpr = SwiftFormulaConverter.packageReaderExpectation(
            packageFilePath: fullPath,
            rootPackageFolder: packageFolder)

        let converterExpr =
            "SwiftFormulaConverter(" +
            "packageFolder: ['\(packageFolder)': Folder(path: '\(packageFolder)').manifest], " +
            "packageJSON: ['\(fullPath)': \(pkgReaderExpr)]" +
            ").formula"

        // Products go *inside* the package folder, not beside it.  A package directory may
        // contain other packages — this repository's root package holds SemelCore,
        // SemelDatabaseModels and GRDB.swift — and placing its product one level up collides
        // with the folder holding theirs.
        return
            "ProjectBuilder(" +
            "outputFolder: '\(packageFolder)', " +
            "projectFile: ['\(packageFolder)': \(converterExpr)]" +
            ").status"
    }
}
