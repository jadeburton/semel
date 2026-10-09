// ErrorConditionConversions.swift
// SemelNodeKit
//
// The condition each of this package's typed errors names, where a node can let one
// through. The errors keep their descriptions for what never travels as a document — a log
// line, a refused request; a report renders the condition.

import SemelDatabaseModels

extension ToolDescriptor {
    /// The descriptor as a report names it, without the fingerprint.
    public var reportedIdentity: ToolIdentity {
        ToolIdentity(name: name, version: version, platform: platform, architecture: architecture)
    }
}

extension ToolError: ErrorConditionConvertible {
    public var errorCondition: ErrorCondition {
        switch self {
        case .noMatchingToolFound(let requested, let available, let namespace, let writer):
            // The settings arrive merged, so which file named the tool is not known here:
            // the machine file is the likely one, written before the toolchain changed, and
            // the writer is named with what makes it replace what it wrote.
            return .toolNotInstalled(requested: requested.reportedIdentity,
                                     available: available.map(\.reportedIdentity)
                                         .sorted { ($0.name, $0.version, $0.platform, $0.architecture)
                                                 < ($1.name, $1.version, $1.platform, $1.architecture) },
                                     namespace: namespace,
                                     writer:    writer.map { MachineFileCommand(writer: $0, folder: nil, rewriting: true) })
        }
    }
}

extension LocalFileSystemToolError: ErrorConditionConvertible {
    public var errorCondition: ErrorCondition {
        switch self {
        case .toolNotFound(let path):                           return .toolNotFound(path: path)
        case .toolNotExecutable(let path):                      return .toolNotExecutable(path: path)
        case .failedToWriteInputFile(let fileName, let underlying):
            return .toolInputNotWritten(file: fileName, reason: "\(underlying)")
        case .failedToReadOutputFile(let fileName):             return .toolOutputNotRead(file: fileName)
        case .processLaunchFailed(let underlying):              return .toolLaunchFailed(reason: "\(underlying)")
        }
    }
}

extension DependencyLockError {
    /// The problem as a report carries it.
    public var problem: LockProblem {
        switch self {
        case .unknownKey(let key, let line):
            return .unknownKey(key: key, line: line, keys: DependencyLock.Key.allCases.map(\.rawValue))
        case .repeatedKey(let key, let line):     return .repeatedKey(key: key, line: line)
        case .emptyValue(let key, let line):      return .emptyValue(key: key, line: line)
        case .missingKey(let key):                return .missingKey(key: key)
        case .unknownContentScheme(let value):    return .unknownContentScheme(value: value, scheme: DependencyLock.contentScheme)
        case .malformedArtifact(let item):        return .malformedArtifact(item: item)
        case .malformedHiddenFile(let path, let line): return .malformedHiddenFile(path: path, line: line)
        }
    }
}

extension TreeMerge.Collision: ErrorConditionConvertible {
    public var errorCondition: ErrorCondition {
        .treeCollision(path: path, first: first, second: second)
    }
}

extension FolderSubtreeManifest.ReadError: ErrorConditionConvertible {
    public var errorCondition: ErrorCondition {
        switch self {
        case .unreadableSubtree(let folder, let hash): return .subtreeUnreadable(folder: folder, hash: hash)
        }
    }
}

extension GraphSpecTableError: ErrorConditionConvertible {
    public var errorCondition: ErrorCondition {
        switch self {
        case .missingRow(let identity): return .specTableMissingRow(identity: identity)
        case .cycle(let identity):      return .specTableCycle(identity: identity)
        }
    }
}

extension TypeRegistryError: ErrorConditionConvertible {
    public var errorCondition: ErrorCondition {
        switch self {
        case .unexpectedType:                return .unexpectedValueType
        case .unknownTypeName(let name):     return .unknownTypeName(name: name)
        case .unknownKind(let kind):         return .unlinkedKind(kind: kind)
        case .notPolySerializable(let kind): return .kindNotSerializable(kind: kind)
        case .notANode(let kind):            return .kindNotANode(kind: kind)
        case .duplicateKind(let kind, let existing, let duplicate):
            return .duplicateKind(kind: kind, existing: existing, duplicate: duplicate)
        }
    }
}

extension GraphSpecIdentityError: ErrorConditionConvertible {
    public var errorCondition: ErrorCondition {
        switch self {
        case .unknownTypeName(let typeName):              return .unknownTypeName(name: typeName)
        case .wireWithoutOutputPort(let wire, let typeName): return .wireWithoutOutputPort(wire: wire, type: typeName)
        }
    }
}

extension GraphSpecParseError: ErrorConditionConvertible {
    public var errorCondition: ErrorCondition {
        switch self {
        case .unexpectedCharacter(let character, let context):
            return .specUnreadable(found: character.map { String($0) }, context: context)
        case .unexpectedEndOfInput(let context):
            return .specUnreadable(found: nil, context: context)
        case .emptyIdentifier:
            return .specUnreadable(found: "", context: "an empty name where a type or a port belongs")
        }
    }
}

extension FolderContentRootError: ErrorConditionConvertible {
    public var errorCondition: ErrorCondition {
        switch self {
        case .unreadable(let path, let reason): return .folderUnreadable(path: path, reason: reason)
        }
    }
}

extension ObjectStoreReadError: ErrorConditionConvertible {
    public var errorCondition: ErrorCondition {
        switch self {
        case .corrupted(let expected, let actual, let path): return .objectCorrupted(path: path, expected: expected, found: actual)
        }
    }
}

extension NodeIdentityError: ErrorConditionConvertible {
    public var errorCondition: ErrorCondition {
        switch self {
        case .nodeNotPersisted(let kind, let name): return .nodeNotPersisted(kind: kind, name: name)
        case .nodeHasNoName(let kind, let nodeID):  return .nodeHasNoName(kind: kind, nodeID: nodeID)
        }
    }
}
