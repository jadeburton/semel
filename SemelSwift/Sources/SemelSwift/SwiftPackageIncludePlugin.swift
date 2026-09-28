// SwiftPackageIncludePlugin.swift
// SemelSwift
//
// What builds a pushed `Package.swift`: the converter a formula includes. Registered so the
// engine can say so when no formula does (B-10).

import SemelNodeKit

struct SwiftPackageIncludePlugin: IncludableProjectPlugin {

    static let manifestFileName = "Package.swift"

    /// `SwiftFormulaConverter(path: <folder>).formula` for a pushed `Package.swift`, nil for
    /// anything else — and nil for one anywhere under a `Dependencies` folder, which is
    /// where `semel-swift` puts a root's git dependencies: the root's converter reads the
    /// ones its targets use, and the rest — a dependency no target uses, a checkout's own
    /// example packages — are someone else's projects, not this tree's to build.
    func includeSpec(forEntry entry: FolderManifestEntry, inFolder folderPath: String) -> GraphSpecNode? {
        guard entry.isPinned, !entry.isFolder, entry.name == Self.manifestFileName else {
            return nil
        }
        let packageFolder = Path(folderPath)
        guard !packageFolder.segments.dropLast().contains(SwiftFormulaConverter.dependenciesFolderName) else {
            return nil
        }
        return GraphSpecNode(SwiftFormulaConverter.self, properties: ["path": packageFolder.string])
            .port(SwiftFormulaConverter.formulaOutput)
    }
}
