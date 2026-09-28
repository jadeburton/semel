// Imports the C target nested in this target's own folder, which the manifest excludes
// from this one: Zip and its Minizip.
import Squeeze

public enum Zipper {
    /// How many runs of one repeated character `text` holds.
    public static func runCount(of text: String) -> Int {
        Int(squeeze_run_count(text))
    }
}
