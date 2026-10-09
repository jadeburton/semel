//
//  FormulaIncludeProviders.swift
//  SemelNodeKit
//
//  Formula text a plugin provides for an include name (B-108). A formula names no plugin
//  until it says `include 'clang'`; the engine then asks every registered provider what
//  that name is, and exactly one may claim it. The formula language and the engine stay
//  agnostic of every plugin: a plugin registers here from its `register()`, the same way
//  it registers its node types, and the engine never names it.

import Foundation

/// What a plugin says about an include name it claims.
public enum FormulaIncludeAnswer: Equatable, Sendable {
    /// Funcs for the formula to call as `namespace.func(…)`. `text` holds `func`
    /// definitions only: a product there would be published in every project that
    /// includes it.
    case prelude(namespace: String, text: String)

    /// The name is this plugin's and cannot be provided here, for `reason` — the client
    /// renders it against the include line.
    case refused(reason: IncludeRefusal)
}

/// A plugin's answer to include names.
///
/// A provider is a pure function of the name and of what the plugin knew when the server
/// started — the tools it found, the SDKs installed. It must not read the input file
/// system: text computed from a project's files is a converter node's, and reaches a
/// formula as `include SwiftFormulaConverter(path: <.>).formula`. The engine asks once per
/// name per start and publishes the answer on a wire, so an answer that changed with
/// anything else would be one the graph never saw.
public protocol FormulaIncludeProvider {
    /// Which plugin this is, as the user knows it: named in a conflict and in the list of
    /// installed plugins when nobody answers.
    var pluginName: String { get }

    /// What this plugin says about `name`: nil when the name is not this plugin's.
    func answer(forIncludeNamed name: String) -> FormulaIncludeAnswer?
}

/// The provider a plugin with one fixed prelude needs: one exact name, one text.
public struct FixedFormulaInclude: FormulaIncludeProvider {
    public let pluginName: String
    public let name:       String
    public let namespace:  String
    public let text:       String

    public init(pluginName: String, name: String, namespace: String, text: String) {
        self.pluginName = pluginName
        self.name       = name
        self.namespace  = namespace
        self.text       = text
    }

    public func answer(forIncludeNamed name: String) -> FormulaIncludeAnswer? {
        name == self.name ? .prelude(namespace: namespace, text: text) : nil
    }
}

/// What the engine makes of an include name once every provider has been asked.
public enum FormulaIncludeResolution: Equatable, Sendable {
    case prelude(namespace: String, text: String)
    /// The condition to publish in place of the prelude: a refusal, a name nobody answers,
    /// or a name two plugins claim.
    case failed(ErrorCondition)
}

public enum FormulaIncludeProviders {

    /// A plugin registers while an engine's compute threads may be resolving includes, and
    /// a Dictionary read concurrent with a write is undefined, not merely stale.
    private static let lock = NSLock()
    private static var byPlugin: [String: any FormulaIncludeProvider] = [:]

    /// Idempotent per plugin, because every plugin's `register()` is.
    public static func register(_ provider: any FormulaIncludeProvider) {
        lock.withLock { byPlugin[provider.pluginName] = provider }
    }

    /// Every registered provider, by plugin name — the registry is a dictionary, and the
    /// order of anything printed has to be imposed.
    public static var all: [any FormulaIncludeProvider] {
        lock.withLock { byPlugin.values.sorted { $0.pluginName < $1.pluginName } }
    }

    /// Forgets every provider. For tests, which register their own.
    public static func removeAll() {
        lock.withLock { byPlugin.removeAll() }
    }

    /// Asks every provider about `name`.
    ///
    /// Two plugins claiming one name — whether each provides or refuses it — is a failure
    /// naming both, never first-wins: the order plugins happened to register in would then
    /// decide what a formula means, and two plugins written by people who never met are
    /// exactly the case to say so loudly.
    public static func resolve(includeNamed name: String) -> FormulaIncludeResolution {
        let claims = all.compactMap { provider in
            provider.answer(forIncludeNamed: name).map { (plugin: provider.pluginName, answer: $0) }
        }

        guard let claim = claims.first else {
            return .failed(.includeUnanswered(name: name, installed: all.map(\.pluginName)))
        }

        guard claims.count == 1 else {
            return .failed(.includeClaimedTwice(name: name, plugins: claims.map(\.plugin)))
        }

        switch claim.answer {
        case .prelude(let namespace, let text):
            return .prelude(namespace: namespace, text: text)
        case .refused(let reason):
            return .failed(.includeRefused(name: name, plugin: claim.plugin, reason: reason))
        }
    }
}
