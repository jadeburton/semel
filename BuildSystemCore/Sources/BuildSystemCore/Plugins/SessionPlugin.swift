// SessionPlugin.swift
// build_system
//
// Handles: base, begin, commit, discard, quit

import Foundation

final class SessionPlugin: CommandPlugin {

    func handle(_ command: UserCommand, context: any CommandContext) throws -> Bool {
        switch command {
        case .base(let externalPath): handleBase(externalPath: externalPath, context: context)
        case .begin:                  break
        case .commit:                 break
        case .discard:                break
        case .quit:                   throw CommandInterpreterError.quit
        default:                      return false
        }
        return true
    }

    // MARK: - base

    private func handleBase(externalPath: String, context: any CommandContext) {
        guard !externalPath.isEmpty else {
            context.outputError("Base path cannot be empty"); return
        }
        let expandedPath = ExternalPathSanitizer.expandPartialPath(externalPath)
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            context.outputError("Path refers to nonexistent directory: \(externalPath)"); return
        }
        context.baseDirectory = expandedPath
        context.outputMessage("Base directory set to \(expandedPath)")
    }
}
