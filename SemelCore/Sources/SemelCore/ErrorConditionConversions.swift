// ErrorConditionConversions.swift
// SemelCore
//
// The condition each of the engine's typed errors names, where a node can meet one: the
// applier's when its demands cannot be applied, the formula parser's in a builder, the
// wiring's. The errors keep their descriptions for the log; a report renders the condition.

import SemelNodeKit

extension GraphSpecApplierError: ErrorConditionConvertible {
    var errorCondition: ErrorCondition {
        switch self {
        case .unknownTypeName(let typeName):
            return .unknownTypeName(name: typeName)
        case .requiredPortUnwired(let typeName, let portName):
            return .requiredPortUnwired(type: typeName, port: portName)
        case .severalWiresOnOneWirePort(let typeName, let portName, let wires):
            return .severalWiresOnOneWirePort(type: typeName, port: portName, wires: wires)
        case .missingOutputPortInChildShape(let typeName):
            return .wireWithoutOutputPort(wire: nil, type: typeName)
        case .identityMismatch(let typeName, let filedUnder, let computed):
            return .identityMismatch(type: typeName, filedUnder: filedUnder, computed: computed)
        case .emtpyStringWireName:
            return .emptyWireName
        case .portNotDeclared(let typeName, let portName):
            return .portNotDeclared(type: typeName, port: portName)
        }
    }
}

extension WireError: ErrorConditionConvertible {
    var errorCondition: ErrorCondition {
        switch self {
        case .attemptToCreateWireWithDuplicateName(let name):
            return .duplicateWireName(name: name)
        case .failedToDeleteWire:
            return .wireNotDisconnected
        case .circularReference(let fromNodeID, let toNodeID):
            return .circularWiring(fromNodeID: fromNodeID, toNodeID: toNodeID)
        case .staticPortWiredAfterCreation(let typeName, let portName):
            return .staticPortWiredAfterCreation(type: typeName, port: portName)
        }
    }
}

extension NodeIdentityError: ErrorConditionConvertible {
    var errorCondition: ErrorCondition {
        switch self {
        case .sourceWithoutIdentity(let nodeID):
            return .sourceWithoutIdentity(nodeID: nodeID)
        }
    }
}

extension FormulaParseError: ErrorConditionConvertible {
    /// A formula error with no position: the parser's own. The builder that meets one names
    /// its formula (`ProjectBuilder.errorSubject`), and the lexer's errors add the line.
    var errorCondition: ErrorCondition {
        .formulaInvalid(path: nil, problem: problem, line: nil, column: nil, lineText: nil)
    }

    var problem: FormulaProblem {
        switch self {
        case .unexpectedToken(let token, let expected):
            return .unexpectedToken(token: "\(token)", expected: expected)
        case .unexpectedCharacter(let character, let context):
            return .unexpectedCharacter(character: String(character), context: context)
        case .unterminatedLiteralString(let context):
            return .unterminatedString(context: context)
        case .unterminatedPathLiteral(let context):
            return .unterminatedPath(context: context)
        case .undefinedIdentifier(let name):
            return .undefinedIdentifier(name: name)
        case .typeMismatch(let expected, let found, let context):
            return .typeMismatch(expected: expected, found: found, context: context)
        case .wrongArgumentCount(let function, let expected, let found):
            return .wrongArgumentCount(function: function, expected: expected, found: found)
        case .positionalArgInNodeConstruction(let typeName):
            return .positionalArgument(type: typeName)
        case .pathEscapesBasePath(let path):
            return .pathEscapesBase(path: path)
        case .pathEscapesRoot(let path):
            return .pathEscapesRoot(path: path)
        case .forEachRequiresAtLeastOneItem:
            return .forEachWithoutItems
        case .forEachExceptLeavesNothing(let variable, let removed):
            return .forEachExceptLeavesNothing(variable: variable, removed: removed)
        case .duplicateDefinition(let kind, let name):
            return .duplicateDefinition(kind: kind, name: name)
        case .unboundParameter(let function, let parameter):
            return .unboundParameter(function: function, parameter: parameter)
        case .namespaceOutsidePrelude(let namespace):
            return .namespaceOutsidePrelude(namespace: namespace)
        case .productInPrelude(let namespace, let product):
            return .productInPrelude(namespace: namespace, product: product)
        case .preludeNotIncluded(let namespace, let callee, let scope):
            return .preludeNotIncluded(namespace: namespace, callee: callee, scope: scope)
        }
    }
}

extension FormulaLexerError: ErrorConditionConvertible {
    var errorCondition: ErrorCondition {
        .formulaInvalid(path: nil, problem: underlying.problem, line: line, column: column,
                        lineText: lineText.isEmpty ? nil : lineText)
    }
}
