// ClangAuditedRegions.swift
// SemelClang
//
// The `#pragma clang arc_cf_code_audited` regions `clang -E` drops, written back into the
// preprocessed text where the headers had them (B-77 item 4).
//
// Under ARC, a Core Foundation function declared inside an audited region follows the
// naming conventions, so ARC knows who owns what it returns and lets an Objective-C object
// be passed to it with a plain cast: Sequel Ace's SPMySQL hands an `NSMutableArray` to
// `CFArrayAppendValue` as `(CFMutableArrayRef)rowArray`. The SDK opens and closes those
// regions with `CF_IMPLICIT_BRIDGING_ENABLED` and `…_DISABLED`, each a `_Pragma`. The
// preprocessor acts on the pragma and prints nothing for it — it prints `assume_nonnull`,
// whose callback it has, and has none for this one — so the compile of the preprocessed
// text sees every CF function as unaudited and refuses the cast, which the same file
// compiled in one step accepts.
//
// Two other routes were measured and not taken. `-frewrite-includes` keeps the pragmas by
// keeping every directive: a test file importing Foundation came to 22.5 MB of text where
// `-E` writes 4.9 MB, every inactive branch of every header kept, and every preprocessed
// text of every project — every compile's key — would change, pragma or none. Telling the
// compile stage the files are audited has no flag to say it with. Writing the pragma lines
// back changes the text of a source only where a header it reads opened a region, so a
// project whose sources include no such header keeps its text and its keys.

import Foundation

enum ClangAuditedRegions {

    static let beginPragma = Array("#pragma clang arc_cf_code_audited begin\n".utf8)
    static let endPragma   = Array("#pragma clang arc_cf_code_audited end\n".utf8)

    /// What one file says about its audited regions: each region by the line that opens it
    /// and the line that closes it, and — for a file that has any — the lines of its
    /// `#include`s and `#import`s, which say where in it a header it includes was entered.
    struct FileFacts {
        var regions: [(begin: Int, end: Int)] = []
        var includeLines: [Int] = []

        static let none = FileFacts()

        /// Read from a header's text: a line that is `CF_IMPLICIT_BRIDGING_ENABLED` or
        /// `…_DISABLED`, the SDK's spelling, or the pragma written out, by itself or as a
        /// `_Pragma`. Openings and closings are paired in order, as clang pairs them.
        ///
        /// ISSUE: a region inside an `#if` the preprocessor skipped is taken as written. One
        /// whose opening and closing are both skipped writes nothing, since no line of the
        /// output falls inside it; the SDK has no region with one end skipped.
        init(text: [UInt8]) {
            guard Self.mentionsARegion(text) else {
                return
            }
            var openedAt: Int?
            var lineNumber = 0
            for line in text.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
                lineNumber += 1
                let words = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                if Self.opens(words) {
                    openedAt = openedAt ?? lineNumber
                    continue
                }
                if Self.closes(words), let begin = openedAt {
                    regions.append((begin: begin, end: lineNumber))
                    openedAt = nil
                    continue
                }
                if Self.isInclusion(words) {
                    includeLines.append(lineNumber)
                }
            }
            if regions.isEmpty {
                includeLines = []
            }
        }

        private init() {}

        private static let markers = ["CF_IMPLICIT_BRIDGING_", "arc_cf_code_audited"].map { Array($0.utf8) }

        /// The cheap test that spares reading lines of a header with no region.
        private static func mentionsARegion(_ text: [UInt8]) -> Bool {
            markers.contains { marker in
                guard let first = marker.first, marker.count <= text.count else {
                    return false
                }
                var index = 0
                let last = text.count - marker.count
                while index <= last {
                    if text[index] == first, text[index..<(index + marker.count)].elementsEqual(marker) {
                        return true
                    }
                    index += 1
                }
                return false
            }
        }

        private static func opens(_ words: String) -> Bool {
            words == "CF_IMPLICIT_BRIDGING_ENABLED" || isPragma(words, ending: "begin")
        }

        private static func closes(_ words: String) -> Bool {
            words == "CF_IMPLICIT_BRIDGING_DISABLED" || isPragma(words, ending: "end")
        }

        private static func isPragma(_ words: String, ending: String) -> Bool {
            let collapsed = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return collapsed == "#pragma clang arc_cf_code_audited \(ending)"
                || collapsed == "_Pragma(\"clang arc_cf_code_audited \(ending)\")"
        }

        private static func isInclusion(_ words: String) -> Bool {
            guard words.hasPrefix("#") else {
                return false
            }
            let directive = words.dropFirst().trimmingCharacters(in: .whitespaces)
            return directive.hasPrefix("include") || directive.hasPrefix("import")
        }
    }

    /// What each header says, read once per process: a source of an Objective-C target reads
    /// a thousand headers, the same thousand as its neighbours. Keyed by an input's content
    /// hash, or by an SDK header's path, which the SDK's fingerprint in every key stands
    /// behind (B-47).
    private static var factsCache: [String: FileFacts] = [:]
    private static let factsCacheLock = NSLock()

    static func cachedFacts(key: String, bytes: () -> [UInt8]?) -> FileFacts {
        if let known = factsCacheLock.withLock({ factsCache[key] }) {
            return known
        }
        let read = bytes().map { FileFacts(text: $0) } ?? .none
        factsCacheLock.withLock { factsCache[key] = read }
        return read
    }

    /// `preprocessed` with the pragma pair written around the text each audited region of a
    /// header it holds covers, or unchanged when no header it holds has one. `facts` reads a
    /// file the line markers name, nil for one that cannot be read — `<built-in>`, a header
    /// outside the SDK and the sandbox — which is taken to have no region.
    ///
    /// A region opens before the first line of the output that comes from inside it, and
    /// before the marker entering a header its file includes inside it; it closes in the
    /// same way after it, or where its file is left. After a pragma written before a line of
    /// text, a line marker puts the file's numbering and its flags — a system header is `3`,
    /// which keeps its warnings quiet — back as they were, so a diagnostic still names the
    /// line it did.
    static func keepingRegions(in preprocessed: [UInt8], facts: (String) -> FileFacts) -> [UInt8] {
        var output: [UInt8] = []
        var frames: [Frame] = []
        var factsByPath: [String: FileFacts] = [:]
        var changed = false
        func factsOf(_ path: String) -> FileFacts {
            if let known = factsByPath[path] {
                return known
            }
            let read = facts(path)
            factsByPath[path] = read
            return read
        }

        let lines = preprocessed.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        output.reserveCapacity(preprocessed.count + 1024)
        for (index, line) in lines.enumerated() {
            let isLast = index == lines.count - 1
            if let marker = LineMarker(line) {
                switch marker.kind {
                case .entering:
                    if var parent = frames.popLast() {
                        let position = parent.facts.includeLines.first { $0 >= parent.line } ?? parent.line
                        changed = parent.advance(to: position, into: &output) || changed
                        frames.append(parent)
                    }
                    frames.append(Frame(path: marker.path, line: marker.line, flags: marker.flags, facts: factsOf(marker.path)))
                case .returning:
                    if var leaving = frames.popLast() {
                        changed = leaving.leave(into: &output) || changed
                    }
                    if var returnedTo = frames.popLast() {
                        returnedTo.line = marker.line
                        frames.append(returnedTo)
                    } else {
                        frames.append(Frame(path: marker.path, line: marker.line, flags: marker.flags, facts: factsOf(marker.path)))
                    }
                case .renumbering:
                    if var current = frames.popLast(), current.path == marker.path {
                        current.line = marker.line
                        current.flags = marker.flags
                        frames.append(current)
                    } else {
                        frames.append(Frame(path: marker.path, line: marker.line, flags: marker.flags, facts: factsOf(marker.path)))
                    }
                }
                output.append(contentsOf: line)
                if !isLast {
                    output.append(UInt8(ascii: "\n"))
                }
                continue
            }
            if var current = frames.popLast() {
                if current.advance(to: current.line, into: &output) {
                    changed = true
                    output.append(contentsOf: current.marker)
                }
                current.line += 1
                frames.append(current)
            }
            output.append(contentsOf: line)
            if !isLast {
                output.append(UInt8(ascii: "\n"))
            }
        }
        return changed ? output : preprocessed
    }

    /// A file on the include stack: where its text has reached, and which of its regions
    /// are done.
    private struct Frame {
        let path: String
        /// The line of the file the next line of output comes from.
        var line: Int
        /// The marker's flags past entering and returning: `3` for a system header, `3 4`
        /// for one read as C.
        var flags: [Int]
        let facts: FileFacts
        var nextRegion = 0
        var isOpen = false

        init(path: String, line: Int, flags: [Int], facts: FileFacts) {
            self.path  = path
            self.line  = line
            self.flags = flags
            self.facts = facts
        }

        /// `# <line> "<path>" <flags>`, which puts the numbering back after a pragma.
        var marker: [UInt8] {
            let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let flagText = flags.map { " \($0)" }.joined()
            return Array("# \(line) \"\(escaped)\"\(flagText)\n".utf8)
        }

        /// Writes what the output owes the file's regions once its text has reached
        /// `position`: the opening of the region it has entered, the closing of the one it
        /// has left. A region it has passed without a line of output inside writes nothing.
        mutating func advance(to position: Int, into output: inout [UInt8]) -> Bool {
            var wrote = false
            while nextRegion < facts.regions.count {
                let region = facts.regions[nextRegion]
                if isOpen {
                    guard position > region.end else {
                        break
                    }
                    output.append(contentsOf: ClangAuditedRegions.endPragma)
                    isOpen = false
                    nextRegion += 1
                    wrote = true
                    continue
                }
                if position > region.end {
                    nextRegion += 1
                    continue
                }
                if position > region.begin {
                    output.append(contentsOf: ClangAuditedRegions.beginPragma)
                    isOpen = true
                    wrote = true
                }
                break
            }
            return wrote
        }

        /// Closes a region still open where the file ends, so the text stays balanced.
        mutating func leave(into output: inout [UInt8]) -> Bool {
            guard isOpen else {
                return false
            }
            output.append(contentsOf: ClangAuditedRegions.endPragma)
            isOpen = false
            return true
        }
    }

    /// One of the preprocessor's line markers, `# 74 "/…/CFArray.h" 3`.
    private struct LineMarker {
        enum Kind { case entering, returning, renumbering }

        let line: Int
        let path: String
        let kind: Kind
        let flags: [Int]

        init?(_ bytes: ArraySlice<UInt8>) {
            guard bytes.count > 4, bytes.first == UInt8(ascii: "#"),
                  bytes[bytes.startIndex + 1] == UInt8(ascii: " "),
                  let digit = bytes.dropFirst(2).first, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) else {
                return nil
            }
            let text = String(decoding: bytes, as: UTF8.self)
            guard let open = text.firstIndex(of: "\""), let close = Self.closingQuote(in: text, after: open),
                  let number = Int(text[text.index(text.startIndex, offsetBy: 2)..<open].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            line = number
            path = String(text[text.index(after: open)..<close])
                .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            let numbers = text[text.index(after: close)...].split(separator: " ").compactMap { Int($0) }
            switch (numbers.contains(1), numbers.contains(2)) {
            case (true, _):  kind = .entering
            case (_, true):  kind = .returning
            default:         kind = .renumbering
            }
            flags = numbers.filter { $0 != 1 && $0 != 2 }
        }

        private static func closingQuote(in text: String, after open: String.Index) -> String.Index? {
            var index = text.index(after: open)
            var escaped = false
            while index < text.endIndex {
                switch (escaped, text[index]) {
                case (true, _):     escaped = false
                case (false, "\\"): escaped = true
                case (false, "\""): return index
                default:            break
                }
                index = text.index(after: index)
            }
            return nil
        }
    }
}
