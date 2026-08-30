//
//  ConfigurationTextTests.swift
//  SemelNodeKitTests
//
//  The shape configuration travels in: one `key=value` per line, read by every node
//  function and written by hand into a config file.
//
//  Because a human writes that file, the parser has to tolerate what a human puts in one --
//  comments, blank lines, a value with an `=` in it -- and it has to be the *same* parser
//  either way, since `ConfigSubset` reads the file with it and the tool reads the wire with
//  it. A rule that held for only one of those would make a file mean two things.
//

@testable import SemelNodeKit
import XCTest

final class ConfigurationTextTests: XCTestCase {

    // MARK: - Reading

    func test_readsOneSettingPerLine() {
        let settings = [String: String](plainText: "a=1\nb=2")

        XCTAssertEqual(settings, ["a": "1", "b": "2"])
    }

    /// A `//` comment is how a config file explains itself, and this tree's own file is
    /// mostly comment. A line with no `=` contributes nothing.
    func test_ignoresCommentLines() {
        let settings = [String: String](plainText: """
            // what this file is for
            a=1
            // and why
            b=2
            """)

        XCTAssertEqual(settings, ["a": "1", "b": "2"])
    }

    /// Blank lines group settings by the node that reads them, which is the only structure
    /// a flat namespace has.
    func test_ignoresBlankLines() {
        let settings = [String: String](plainText: "\na=1\n\n\nb=2\n")

        XCTAssertEqual(settings, ["a": "1", "b": "2"])
    }

    /// Only the first `=` separates. Tool version strings contain them, and a key cannot,
    /// so splitting on the last one or on every one would corrupt exactly the setting that
    /// pins the toolchain.
    func test_splitsOnTheFirstEqualsOnly() {
        let settings = [String: String](plainText: "toolDescriptor.version=Apple Swift version 6.3.3 (a=b)")

        XCTAssertEqual(settings["toolDescriptor.version"], "Apple Swift version 6.3.3 (a=b)")
    }

    /// A key with nothing after the `=` is absent, not present-and-empty. That is what lets
    /// an optional value round-trip: it is written as empty and read back as missing, so a
    /// tool asking whether the key was supplied gets the same answer either side.
    func test_readsAKeyWithNoValueAsAbsent() {
        let settings = [String: String](plainText: "a=\nb=2")

        XCTAssertNil(settings["a"])
        XCTAssertEqual(settings["b"], "2")
    }

    /// The case that makes `//` worth recognising rather than merely failing to parse:
    /// commenting a setting out is how one gets disabled, and a commented setting still
    /// splits on `=` like any other line.
    func test_aCommentedOutSettingIsNotInForce() {
        let settings = [String: String](plainText: """
            // swift.compiler.sdkVersion=26.5
            a=1
            """)

        XCTAssertEqual(settings, ["a": "1"])
    }

    /// Only a *leading* `//`. There is no trailing-comment form, so a value containing one
    /// keeps it — a URL or a network path would otherwise be silently truncated.
    func test_aDoubleSlashInsideAValueIsPartOfTheValue() {
        let settings = [String: String](plainText: "a=https://example.com/x")

        XCTAssertEqual(settings["a"], "https://example.com/x")
    }

    /// A single leading slash is not a comment; only a pair is.
    func test_aSingleLeadingSlashIsNotAComment() {
        let settings = [String: String](plainText: "/a=1")

        XCTAssertEqual(settings["/a"], "1")
    }

    // MARK: - Writing

    /// Sorted, because this text becomes a wire value and a wire value is compared for
    /// equality. Dictionary iteration order is seeded per process, so an unsorted render
    /// would make an unchanged configuration look changed on the next run.
    func test_writesKeysInSortedOrder() {
        XCTAssertEqual(["b": "2", "a": "1", "c": "3"].asPlainText(), "a=1\nb=2\nc=3")
    }

    func test_writingThenReadingRoundTrips() {
        let original = ["toolDescriptor.name": "swiftc", "sdkVersion": "26.5"]

        XCTAssertEqual([String: String](plainText: original.asPlainText()), original)
    }

    // MARK: - Merging

    /// `mergedWith` is how manifest-derived literals overlay a selector's output, so the
    /// argument has to win: what a target *is* must not be overridable by a config file.
    func test_mergingLetsTheArgumentWin() {
        XCTAssertEqual(["a": "1", "b": "2"].mergedWith(["b": "9"]), ["a": "1", "b": "9"])
    }
}
