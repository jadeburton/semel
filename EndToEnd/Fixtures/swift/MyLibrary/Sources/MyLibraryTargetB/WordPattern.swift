// Compiles only with the settings the manifest gives this target: without the `.define`,
// the `#error` stops it; without the upcoming feature, Swift 5 mode reads the regex
// literal's slashes as division and the line does not parse.

#if !MY_LIBRARY_SETTINGS
#error("MyLibraryTargetB compiles with its manifest's .define(\"MY_LIBRARY_SETTINGS\")")
#endif

@available(macOS 13, iOS 16, *)
public enum WordPattern {
    /// The first run of lowercase letters in `text`.
    public static func firstWord(in text: String) -> String? {
        text.firstMatch(of: /[a-z]+/).map { String($0.output) }
    }
}
