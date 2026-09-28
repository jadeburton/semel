//
//  SelectedNamespaces.swift
//  SemelMachineFile
//
//  Which config namespaces a formula selects, read from its text: the blocks a machine
//  file must hold for it, and no more, since the engine reports a key no `ConfigFilter`
//  claims as unused on every build. Both writers ask — `semel-swift prepare` for a formula
//  it keeps, `semel-clang` for the formulas that read the file it writes.

import Foundation
import SemelNodeKit

extension MachineFile {

    /// The namespaces a formula's text selects, from its `prefix: '…'` literals: what a
    /// hand-written formula names in `ConfigFilter(prefix: 'swift.compiler', …)` or through
    /// a func of its own, `settings(prefix: 'apple.assetCatalogCompiler')`. A prefix passed
    /// as a parameter is not a literal and does not count. Sorted, each once.
    ///
    /// A formula that says `include 'clang'` selects what the prelude funcs it calls select
    /// (B-108): `clang.executable(…)` reaches `linked`, `compiled` and `preprocessed`, whose
    /// bodies carry the linker's, the compiler's and the preprocessor's prefixes, and not
    /// `staticLibrary`, whose body carries the archiver's. So each prelude is read func by
    /// func, from the `namespace.func(` calls the formula makes through the funcs those
    /// bodies call in turn — a whole prelude would select every tool it can wire, and a
    /// project that links nothing through the archiver would be told on every build that
    /// the archiver's keys are unused. The formula's own text counts whole, whether or not
    /// its funcs are called, as it always has.
    public static func namespaces(selectedIn formula: String) -> [String] {
        let formulaText = withoutCommentLines(formula)
        var selected    = Set(prefixLiterals(in: formulaText))

        // Every prelude the formula reaches, by the namespace its funcs are called under,
        // and each one's funcs by name.
        var preludes      = [String: [String: String]]()
        var pendingTexts  = [formulaText]
        var includedNames = Set<String>()
        while let text = pendingTexts.popLast() {
            for name in captures(of: #"include\s+'([^']+)'"#, in: text) where includedNames.insert(name).inserted {
                guard case .prelude(let namespace, let prelude) = FormulaIncludeProviders.resolve(includeNamed: name) else {
                    continue
                }
                let preludeText = withoutCommentLines(prelude)
                preludes[namespace] = funcBodies(in: preludeText)
                pendingTexts.append(preludeText)
            }
        }

        // The funcs reached, from the formula's dotted calls through each body's calls: a
        // plain call names a func of the same prelude, a dotted one a func of another.
        var pendingCalls = dottedCalls(in: formulaText, preludes: preludes)
        var reached      = Set<PreludeFunc>()
        while let call = pendingCalls.popLast() {
            guard reached.insert(call).inserted, let body = preludes[call.namespace]?[call.name] else {
                continue
            }
            selected.formUnion(prefixLiterals(in: body))
            pendingCalls += dottedCalls(in: body, preludes: preludes)
            for name in captures(of: #"(?<![\w.])([A-Za-z_]\w*)\s*\("#, in: body) where preludes[call.namespace]?[name] != nil {
                pendingCalls.append(PreludeFunc(namespace: call.namespace, name: name))
            }
        }
        return selected.sorted()
    }

    private struct PreludeFunc: Hashable {
        let namespace: String
        let name:      String
    }

    private static func prefixLiterals(in text: String) -> [String] {
        captures(of: #"prefix:\s*'([A-Za-z][A-Za-z0-9.]*)'"#, in: text)
    }

    /// `clang.executable(` in `text`, for each prelude namespace that has such a func.
    private static func dottedCalls(in text: String, preludes: [String: [String: String]]) -> [PreludeFunc] {
        let expression = #"(?<![\w.])([A-Za-z_]\w*)\.([A-Za-z_]\w*)\s*\("#
        guard let regex = try? NSRegularExpression(pattern: expression) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let namespaceRange = Range(match.range(at: 1), in: text),
                  let nameRange      = Range(match.range(at: 2), in: text) else {
                return nil
            }
            let call = PreludeFunc(namespace: String(text[namespaceRange]), name: String(text[nameRange]))
            return preludes[call.namespace]?[call.name] == nil ? nil : call
        }
    }

    /// A prelude's funcs by name, each with its text up to the next `func` that starts a
    /// line: a prelude holds `func` definitions only, and a body's continuation lines are
    /// indented under the line that opens it.
    private static func funcBodies(in prelude: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^func\s+([A-Za-z_]\w*)"#) else {
            return [:]
        }
        let text    = prelude as NSString
        let matches = regex.matches(in: prelude, range: NSRange(location: 0, length: text.length))
        var bodies  = [String: String]()
        for (index, match) in matches.enumerated() {
            let end   = index + 1 < matches.count ? matches[index + 1].range.location : text.length
            let range = NSRange(location: match.range.location, length: end - match.range.location)
            bodies[text.substring(with: match.range(at: 1))] = text.substring(with: range)
        }
        return bodies
    }

    /// `text` without its whole-line `//` comments, which describe calls in prose — the
    /// fixtures' formulas explain `include 'clang'` above the line that says it.
    private static func withoutCommentLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The first capture group of every match of `pattern` in `text`.
    private static func captures(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }
}
