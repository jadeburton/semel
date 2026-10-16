//
//  CMakeCondition.swift
//  SemelCMake
//
//  `if(…)` as the declarative subset reads it: constants, variables, `DEFINED`, string,
//  number and version comparisons, `IN_LIST`, `NOT`, `AND`, `OR` and parentheses. Anything
//  else — `MATCHES`, `EXISTS`, `TARGET`, `COMMAND`, a comparison reading a version the
//  machine would supply — is undecidable here, and the block it guards is reported and
//  skipped rather than guessed at.
//

/// One argument of the condition as the evaluator expanded it: a quoted argument names no
/// variable, as CMake reads it under CMP0054.
struct CMakeConditionToken: Equatable {
    var text: String
    var quoted: Bool
}

enum CMakeConditionError: Error, Equatable {
    /// The operator or test named, which the subset does not decide.
    case undecidable(String)
    case malformed
}

struct CMakeCondition {
    private let tokens: [CMakeConditionToken]
    private let variables: [String: String]
    private var index = 0

    init(tokens: [CMakeConditionToken], variables: [String: String]) {
        self.tokens    = tokens
        self.variables = variables
    }

    /// The condition's truth under the variables, or why it has none.
    static func evaluate(_ tokens: [CMakeConditionToken], variables: [String: String]) throws -> Bool {
        var condition = CMakeCondition(tokens: tokens, variables: variables)
        let value = try condition.parseOr()
        guard condition.index == tokens.count else {
            throw CMakeConditionError.malformed
        }
        return value
    }

    /// The text of the condition, for a report.
    static func text(of tokens: [CMakeConditionToken]) -> String {
        tokens.map { $0.quoted ? "\"\($0.text)\"" : $0.text }.joined(separator: " ")
    }

    // MARK: - Grammar

    private var current: CMakeConditionToken? { index < tokens.count ? tokens[index] : nil }

    private func isKeyword(_ keyword: String) -> Bool {
        guard let current, !current.quoted else {
            return false
        }
        return current.text == keyword
    }

    private mutating func parseOr() throws -> Bool {
        var value = try parseAnd()
        while isKeyword("OR") {
            index += 1
            let right = try parseAnd()
            value = value || right
        }
        return value
    }

    private mutating func parseAnd() throws -> Bool {
        var value = try parseNot()
        while isKeyword("AND") {
            index += 1
            let right = try parseNot()
            value = value && right
        }
        return value
    }

    private mutating func parseNot() throws -> Bool {
        if isKeyword("NOT") {
            index += 1
            return try !parseNot()
        }
        return try parseComparison()
    }

    private static let undecidableTests: Set<String> = [
        "EXISTS", "IS_DIRECTORY", "IS_SYMLINK", "IS_ABSOLUTE", "IS_NEWER_THAN", "COMMAND", "POLICY",
        "TARGET", "TEST", "MATCHES", "PATH_EQUAL",
    ]

    private mutating func parseComparison() throws -> Bool {
        if isKeyword("DEFINED") {
            index += 1
            guard let name = current else {
                throw CMakeConditionError.malformed
            }
            index += 1
            return variables[name.text] != nil
        }
        if let current, !current.quoted, Self.undecidableTests.contains(current.text) {
            throw CMakeConditionError.undecidable(current.text)
        }
        if isKeyword("(") {
            index += 1
            let value = try parseOr()
            guard isKeyword(")") else {
                throw CMakeConditionError.malformed
            }
            index += 1
            return value
        }
        guard let left = current else {
            throw CMakeConditionError.malformed
        }
        index += 1
        guard let operatorToken = current, !operatorToken.quoted else {
            return truth(of: left)
        }
        switch operatorToken.text {
        case "STREQUAL", "STRLESS", "STRGREATER", "STRLESS_EQUAL", "STRGREATER_EQUAL",
             "EQUAL", "LESS", "GREATER", "LESS_EQUAL", "GREATER_EQUAL", "IN_LIST",
             "VERSION_EQUAL", "VERSION_LESS", "VERSION_GREATER", "VERSION_LESS_EQUAL", "VERSION_GREATER_EQUAL":
            index += 1
            guard let right = current else {
                throw CMakeConditionError.malformed
            }
            index += 1
            return try compare(left, operatorToken.text, right)
        case _ where Self.undecidableTests.contains(operatorToken.text):
            throw CMakeConditionError.undecidable(operatorToken.text)
        default:
            return truth(of: left)
        }
    }

    // MARK: - Values

    /// A variable's value when the token is an unquoted name of one, else the text.
    private func value(of token: CMakeConditionToken) -> String {
        if !token.quoted, let value = variables[token.text] {
            return value
        }
        return token.text
    }

    private static let trueConstants: Set<String>  = ["1", "ON", "YES", "TRUE", "Y"]
    private static let falseConstants: Set<String> = ["0", "OFF", "NO", "FALSE", "N", "IGNORE", "NOTFOUND", ""]

    /// A constant by its own value; a variable by the value it holds, unset reading as
    /// false; a quoted string that is no constant is false.
    private func truth(of token: CMakeConditionToken) -> Bool {
        let upper = token.text.uppercased()
        if Self.trueConstants.contains(upper) {
            return true
        }
        if Self.falseConstants.contains(upper) || upper.hasSuffix("-NOTFOUND") {
            return false
        }
        if let number = Double(token.text) {
            return number != 0
        }
        guard !token.quoted, let held = variables[token.text] else {
            return false
        }
        let heldUpper = held.uppercased()
        if Self.falseConstants.contains(heldUpper) || heldUpper.hasSuffix("-NOTFOUND") {
            return false
        }
        if let number = Double(held) {
            return number != 0
        }
        return true
    }

    private func compare(_ left: CMakeConditionToken, _ operation: String, _ right: CMakeConditionToken) throws -> Bool {
        for token in [left, right] where !token.quoted && variables[token.text] == nil
            && CMakeFacts.machineVariables.contains(token.text) {
            throw CMakeConditionError.undecidable(token.text)
        }
        let leftValue  = value(of: left)
        let rightValue = value(of: right)
        switch operation {
        case "STREQUAL":         return leftValue == rightValue
        case "STRLESS":          return leftValue < rightValue
        case "STRGREATER":       return leftValue > rightValue
        case "STRLESS_EQUAL":    return leftValue <= rightValue
        case "STRGREATER_EQUAL": return leftValue >= rightValue
        case "IN_LIST":
            // The right side names a list variable, never a value.
            let list = variables[right.text] ?? ""
            return list.split(separator: ";").contains { String($0) == leftValue }
        case "VERSION_EQUAL", "VERSION_LESS", "VERSION_GREATER", "VERSION_LESS_EQUAL", "VERSION_GREATER_EQUAL":
            let leftVersion  = Self.versionComponents(of: leftValue)
            let rightVersion = Self.versionComponents(of: rightValue)
            switch operation {
            case "VERSION_EQUAL":         return leftVersion == rightVersion
            case "VERSION_LESS":          return leftVersion.lexicographicallyPrecedes(rightVersion)
            case "VERSION_GREATER":       return rightVersion.lexicographicallyPrecedes(leftVersion)
            case "VERSION_LESS_EQUAL":    return !rightVersion.lexicographicallyPrecedes(leftVersion)
            case "VERSION_GREATER_EQUAL": return !leftVersion.lexicographicallyPrecedes(rightVersion)
            default:                      throw CMakeConditionError.undecidable(operation)
            }
        default:
            // A number comparison of something that is no number is false, as CMake's is.
            guard let leftNumber = Double(leftValue), let rightNumber = Double(rightValue) else {
                return false
            }
            switch operation {
            case "EQUAL":         return leftNumber == rightNumber
            case "LESS":          return leftNumber < rightNumber
            case "GREATER":       return leftNumber > rightNumber
            case "LESS_EQUAL":    return leftNumber <= rightNumber
            case "GREATER_EQUAL": return leftNumber >= rightNumber
            default:              throw CMakeConditionError.undecidable(operation)
            }
        }
    }

    /// `major[.minor[.patch[.tweak]]]` as CMake compares it: four integers, a missing
    /// component zero, and a component's non-digit tail dropped — `3.12rc1` is `3.12`.
    static func versionComponents(of text: String) -> [Int] {
        var components = text.split(separator: ".", omittingEmptySubsequences: false).map { component in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
        while components.count < 4 {
            components.append(0)
        }
        return Array(components.prefix(4))
    }
}
