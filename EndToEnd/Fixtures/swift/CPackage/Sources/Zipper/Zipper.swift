// Imports the C target nested in this target's own folder, which the manifest excludes
// from this one: Zip and its Minizip. The manifest names it for macOS alone, as
// LanguageClient names ProcessEnv (B-77): dropped, this import has no module.
import Squeeze

// SwiftPM compiles every package target with this condition, and code branches on it:
// GRDB 6 imports its SQLite shims under it (B-77).
#if !SWIFT_PACKAGE
#error("Zipper is compiled as a package target, with SWIFT_PACKAGE defined")
#endif

public enum Zipper {
    /// How many runs of one repeated character `text` holds.
    public static func runCount(of text: String) -> Int {
        Int(squeeze_run_count(text))
    }

    /// Seen by the package's other targets and no one else's: `App` calls it, which
    /// compiles only when both are compiled in one named package (B-77), as
    /// CodeEditTextView's `package(set)` properties are.
    package static func squeezedLength(of text: String) -> Int {
        text.count - runCount(of: text)
    }
}
