// RunningNodeNames.swift
// SemelMonitor
//
// What the running card and the live window call each running node (B-168): its type, and
// what it is computed for as the error report names a subject — a compile by its module, a
// compiler by its source, a linker by its product — written through the report's own
// `SubjectNames`. A node that names no subject is called by the name the record gives it,
// its path, and one that has neither by its type alone. Two running nodes the same so far —
// one module compiled under two configurations — are told apart by the start of their
// identities, the hash of each one's spec, which the engine sends for the purpose.
//
//     SwiftCompiler  Models
//     ClangCompiler  Sources/App/main.m
//     SwiftCompiler  Models #3fa2c1d0
//     SwiftCompiler  Models #9b04e7aa

import SemelCLI
import SemelProtocol

public enum RunningNodeNames {

    /// How many characters of an identity tell two nodes apart: as many as a short commit
    /// name has, which is plenty among the few nodes running at once.
    public static let identityShown = 8

    /// What each of `nodes` is computed for, in their order: the subject's value, else the
    /// record's name, empty for a node with neither, and the start of the identity after it
    /// for each node another of the list has the same type and the same words as.
    public static func subjects(of nodes: [ActiveNode]) -> [String] {
        let plain = nodes.map(plainSubject(of:))
        var occurrences: [String: Int] = [:]
        for (node, subject) in zip(nodes, plain) {
            occurrences[node.type + "\u{0}" + subject, default: 0] += 1
        }
        return zip(nodes, plain).map { node, subject in
            guard occurrences[node.type + "\u{0}" + subject, default: 0] > 1, !node.identity.isEmpty else {
                return subject
            }
            let tag = "#" + node.identity.prefix(identityShown)
            return subject.isEmpty ? tag : "\(subject) \(tag)"
        }
    }

    /// `SwiftCompiler  Models`, one line per node in their order; the type alone for a node
    /// with nothing to add.
    public static func lines(of nodes: [ActiveNode]) -> [String] {
        zip(nodes, subjects(of: nodes)).map { node, subject in
            subject.isEmpty ? node.type : "\(node.type)  \(subject)"
        }
    }

    /// The subject's value as the error report writes it, else the record's name as a path
    /// on disk is written.
    static func plainSubject(of node: ActiveNode) -> String {
        if let subject = node.subject {
            return SubjectNames.value(of: subject)
        }
        return SubjectNames.displayed(node.name)
    }
}
