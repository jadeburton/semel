// SessionPlugin.swift
// build_system
//
// Handles: base, begin, commit, discard, q / quit / exit

import Foundation
import SemelNodeKit

final class SessionPlugin: CommandPlugin {

    let verbs: Set<String> = ["base", "begin", "commit", "discard", "q", "quit", "exit"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "base":
            handleBase(externalPath: tokens.first, context: context)

        case "begin", "commit", "discard":
            break

        case "q", "quit", "exit":
            throw CommandInterpreterError.quit

        default:
            break
        }
    }

    // MARK: - base

    private func handleBase(externalPath: String?, context: any CommandContext) {
        guard let externalPath else {
            context.outputMessage(context.baseDirectory)
            return
        }

        let expandedPath = ExternalPathSanitizer.expandPartialPath(externalPath)
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            context.outputError("Path refers to nonexistent directory: \(externalPath)"); return
        }
        context.baseDirectory = expandedPath
        context.outputMessage("Base directory set to \(expandedPath)")
    }
}
