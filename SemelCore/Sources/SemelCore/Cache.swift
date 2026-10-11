//
//  Cache.swift
//  semel
//
//  Created by Jade Burton on 14.06.26.
//
//  The engine's side of the cache: the material a node's key is taken of, built from the
//  node and its inputs, and the two hooks a run goes through — the lookup before it and
//  the write after. What an entry is, how a key is hashed and how the store is kept are
//  `SemelCache`'s, shared with a cache server.
//

import Foundation
import SemelCache
import SemelNodeKit

extension Node {

    /// The property `ProjectBuilder` stamps on every cacheable node it builds a product
    /// through.
    static var projectRootProperty: String { "projectRoot" }

    /// A wire key relative to the node's project root, when it has one and the key lies
    /// under it; the key whole otherwise. Two developers who point `base` at different
    /// folders put the same project at different places under `input:`; the remainder is
    /// what both builds have in common. A key of another shape — `wire0`, `product`,
    /// `modules/…` — keeps more in the key, never less. A wire equal to the root itself
    /// becomes `"."`, the empty remainder — otherwise it would key on the absolute path
    /// the root strips from every other wire.
    func projectRelative(wire: String) -> String {
        guard let root = thisNode.properties[Self.projectRootProperty], !root.isEmpty else {
            return wire
        }
        let trimmedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        if wire == trimmedRoot {
            return "."
        }
        let prefix = trimmedRoot + "/"
        guard wire.hasPrefix(prefix) else {
            return wire
        }
        return String(wire.dropFirst(prefix.count))
    }

    func buildCacheKeyEntriesFromOneInput(inputPort: String, input: ProcessInput) throws -> [CacheKeyEntry] {
        // Keying on a partial input set would produce a key that collides with a
        // different set of inputs — the one failure mode a cache must never have.
        guard let oneInput = input.inputValues[inputPort] else {
            throw NodeError.inputPortMissing(port: inputPort)
        }

        // Both halves matter.  The wire key is the file's path, and the tools embed it —
        // in the object file's debug info, in the output filename derived from it, and in
        // the compiler output published on the log ports.  Keying on the values alone
        // meant identical content at a different path scored a hit and came back with
        // another file's build. The wire key therefore stays in the key whole: a
        // project-relative key is sound only once the sandbox materialises inputs at the
        // project-relative path and the command lines carry that path, which is what
        // `projectRelative(wire:)` is for and what B-49's remaining part owes.
        return oneInput
            .sorted { $0.key < $1.key }
            .map { CacheKeyEntry(port: inputPort, wire: $0.key, value: $0.value) }
    }

    /// Everything this node's key is taken of, in the order it is hashed: the node's type
    /// and the implementation of that type, its properties less the excluded ones,
    /// whatever it declares it reads from outside its inputs (`cacheKeyMaterial`), and
    /// every wired input with the value it carried.
    ///
    /// The implementation version is what makes an entry say which code produced it: a
    /// type that changes what it emits for equal inputs bumps it and stops hitting what it
    /// wrote before, while every other type keeps its entries.
    ///
    /// The key is the hash of this structure's canonical text and is computed nowhere
    /// else, so the material stored with an entry is the material that keyed it rather
    /// than a description of it that can drift.
    func buildCacheKeyMaterial(input: ProcessInput) throws -> CacheKeyMaterial {
        let excluded = Self.cacheKeyExcludedProperties
        let properties = thisNode.properties
            .filter { !excluded.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { CacheKeyProperty(key: $0.key, value: $0.value) }

        var inputs: [CacheKeyEntry] = []
        for inputPort in descriptor.staticInputPorts.sorted() + descriptor.dynamicInputPorts.sorted() {
            inputs += try buildCacheKeyEntriesFromOneInput(inputPort: inputPort, input: input)
        }

        return CacheKeyMaterial(nodeType: String(describing: type(of: self)),
                                implementationVersion: Self.implementationVersion,
                                properties: properties,
                                fingerprint: try cacheKeyMaterial(input: input),
                                inputs: inputs)
    }

    func buildCacheKeyFromAllInputs(input: ProcessInput) throws -> String? {
        try buildCacheKeyMaterial(input: input).cacheKey()
    }

    /// The entry stored under `cacheKey`, as the graph applies it: the values, and the
    /// demands as the stored table, which the applier walks by identity — no tree is built
    /// and none is hashed (B-121).
    ///
    /// On a local miss the shared cache is asked, when the home names one (B-153): its entry,
    /// with every object it holds fetched into the object store and verified, is written
    /// into the local cache and answers as a local one would. Every failure on that path is
    /// a miss, counted by the shared cache and never thrown, so a remote can make a node's
    /// lookup slower and never make it fail.
    func loadCachedOutputs(cacheKey: String?) throws -> AppliedOutput? {

        guard let cacheKey, descriptor.cachesOutputs else {
            return nil
        }

        if descriptor.staticInputPorts.isEmpty && descriptor.dynamicInputPorts.isEmpty {
            return nil
        }

        if descriptor.outputPorts.isEmpty {
            return nil
        }

        // A row whose bytes are not an entry this Semel reads is a miss, as no row is.
        if let local = try database.cacheEntry.entry(forKey: cacheKey) {
            return try applied(local, cacheKey: cacheKey, fetched: nil)
        }
        // A type with no static input port never writes an entry (`saveCacheFor…`), so no
        // engine has put one there to fetch, and the round trip would be for nothing.
        guard !descriptor.staticInputPorts.isEmpty, let sharedCache = BuildEngine.shared?.sharedCache else {
            return nil
        }
        let lookup = sharedCache.fetch(key: CacheKey(hash: cacheKey))
        guard let remote = lookup.fetched else {
            Debug.log("the shared cache: \(lookup.debugName) for \(type(of: self)), nodeID \(thisNode.id ?? -1)")
            return nil
        }
        return try applied(remote.entry, cacheKey: cacheKey, fetched: remote)
    }

    /// An entry found under `cacheKey` — in the local cache, or fetched from the shared one
    /// — as the graph applies it, or nil when this Semel cannot apply it. A fetched entry
    /// that can be is written into the local cache with the objects the shared cache said it
    /// holds, so the next lookup is local and the trim and the collector account for it.
    private func applied(_ decodedCacheEntry: ProcessCacheEntry, cacheKey: String,
                         fetched: FetchedEntry?) throws -> AppliedOutput? {

        // An entry's specs demand a subgraph by naming node types, and a node type carries
        // no version for a type other than its own: a Semel that drops or renames a type
        // leaves entries of every *other* type naming something it cannot make. Applying
        // such an entry is recoverable — the throw writes an error value on every output
        // port and both hit paths reprocess — so this saves a replay that was going to be
        // thrown away, along with its warning and the error values the ports carry
        // meanwhile. Asked of the table's rows, so once per distinct node.
        guard decodedCacheEntry.specTable.namesOnlyRegisteredTypes() else {
            return nil
        }

        // A table naming a row it does not hold is damaged, and a damaged entry is a miss.
        // A lookup per reference, nothing hashed: a row filed under the wrong identity is
        // caught by the applier, which checks a row before making a node from it.
        guard decodedCacheEntry.specTable.referencesOnlyHeldRows() else {
            return nil
        }

        if let fetched {
            // Stamped as used by the settle in progress, as every write is.
            try database.cacheEntry.save(hash: cacheKey,
                                         nodeType: decodedCacheEntry.keyMaterial.nodeType,
                                         cost: fetched.cost,
                                         content: fetched.content,
                                         objects: fetched.objects)
            Debug.log("using the shared cache: \(type(of: self)), nodeID \(thisNode.id ?? -1)")
            return AppliedOutput(outputValues: decodedCacheEntry.outputValues,
                                 specTable: decodedCacheEntry.specTable)
        }

        // Below every reason this lookup can answer nothing, so only a row that was used
        // counts as used by this settle. Eviction spares what the last settle used, so
        // stamping a row before reading it would spare the rejected ones — an entry this
        // Semel cannot decode, or one demanding a type it does not link, would hold its
        // bytes in the cache against the entries that do get used.
        //
        // Best effort: a missed stamp only makes the entry evictable sooner.
        FatalErrors.attempt {
            try database.cacheEntry.noteUse(hash: cacheKey)
        }

        Debug.log("using cache: \(type(of: self)), nodeID \(thisNode.id ?? -1)")

        return AppliedOutput(outputValues: decodedCacheEntry.outputValues,
                             specTable: decodedCacheEntry.specTable)
    }

    /// Stores one build under the key its material takes, and the material with it. The
    /// material rather than the key is what is passed in: an entry whose key nothing can
    /// account for is the state B-13 exists to remove, and taking the key here is what
    /// makes that impossible to reach.
    ///
    /// The output is the applied one, whose table is what was wired: the demands are
    /// folded once per run, for the graph and for the entry both.
    ///
    /// Whether an entry is written is the type's declaration (`cachesOutputs`) and nothing
    /// else. The duration is stored as the entry's cost; it decides no value, because an
    /// entry that existed only when a run was slow enough would make the next settle depend
    /// on the machine's load. What it weighs is which entry goes first when the cache is
    /// over its limit, which is a question about the machine's resources (B-148).
    ///
    /// The entry is stored with the objects it holds, as the collector would follow them
    /// from its outputs, and their sizes: that is what the cache's running total is kept
    /// from, so a trim reads rows and never the store. Here the store is read — a stat
    /// per object, and the first bytes of each to see whether it is a document naming
    /// more — which is the price of the total, paid once per entry written.
    ///
    /// Not every result is worth an entry (`isWorthStoring`): a node's own failure is, and a
    /// state carried from its inputs, or a run over a removed source, is not.
    func saveCacheForAllInputsAndOutputs(keyMaterial: CacheKeyMaterial?,
                                         processingDuration: TimeInterval,
                                         output: AppliedOutput) throws {
        guard let keyMaterial, descriptor.cachesOutputs,
              Self.isWorthStoring(outputValues: output.outputValues, keyMaterial: keyMaterial) else {
            return
        }
        if descriptor.staticInputPorts.isEmpty {
            return
        }

        if descriptor.outputPorts.isEmpty {
            return
        }

        let cacheEntry = ProcessCacheEntry(outputValues: output.outputValues,
                                           specTable: output.specTable,
                                           keyMaterial: keyMaterial)
        let key     = try cacheEntry.key()
        let cost    = CacheCost.milliseconds(of: processingDuration)
        let content = try cacheEntry.encoded()
        let objects = BuildEngine.heldObjects(outputValues: output.outputValues, in: DataObjectStore.shared)

        // Replaces rather than refuses: a key whose row this Semel could not read is a key
        // it just missed on, and the build that missed is the one thing that can put a
        // readable entry there.
        try database.cacheEntry.save(hash: key.hash, nodeType: keyMaterial.nodeType, cost: cost,
                                     content: content, objects: objects)

        // Handed to the shared cache's queue, which writes it on a thread of its own: this
        // returns at once whatever the server is doing, and a server that never takes it
        // costs the entry, never the settle (B-153).
        BuildEngine.shared?.sharedCache?.populate(PopulationItem(key: key, cost: cost, objects: objects, content: content))
    }
}

extension Node {

    /// Whether a run's result is one a later run with the same key should be answered with.
    ///
    /// A failure of the node's own is: a compile error is as much a function of the inputs
    /// as an object file, and replaying it spares the run that would say it again. Two
    /// results are not (B-149):
    ///
    /// - **Only carried states.** Every port saying the node did not produce because of an
    ///   input — `inputInError`, `inputNotProduced` — says nothing its inputs do not, costs
    ///   nothing to say again, and is what the engine publishes without a run when the
    ///   input is on a static port (`stateStoppingProcess`).
    /// - **A removed source among the inputs.** A removal is a state of the outside world
    ///   that the graph leaves as soon as what demanded the source lets go of it, or the
    ///   source is pushed back, which moves the key. A key over it names a moment of the
    ///   input file system, and its entry would only take room from builds a settle can use.
    ///
    /// A `pending` output is stored: it is what a walk publishes with the demands it has
    /// found so far, and a hit replays the walk without running it.
    static func isWorthStoring(outputValues: [String: NodeValue], keyMaterial: CacheKeyMaterial) -> Bool {
        let onlyCarried = !outputValues.isEmpty && outputValues.values.allSatisfy { value in
            switch value {
            case .noValue(.inputInError), .noValue(.inputNotProduced):
                return true
            case .value, .noValue(.pending), .noValue(.initializing), .noValue(.deleted), .noValue(.error):
                return false
            }
        }
        guard !onlyCarried else {
            return false
        }
        return !keyMaterial.inputs.contains { entry in
            if case .noValue(.deleted) = entry.value {
                return true
            }
            return false
        }
    }
}

/// An output as the graph applies it: the values for the node's ports, and its demands as
/// a table (B-121). What a cache hit hands back, and what a run's output becomes once its
/// trees are folded — so one applier serves both, and the table a run applies is the one
/// its entry stores.
struct AppliedOutput {
    let outputValues: [String: NodeValue]
    let specTable: GraphSpecTable

    init(outputValues: [String: NodeValue], specTable: GraphSpecTable) {
        self.outputValues = outputValues
        self.specTable    = specTable
    }

    /// A run's output with its demanded trees folded, each node hashed once.
    init(folding output: ProcessOutput) throws {
        self.init(outputValues: output.outputValues, specTable: try GraphSpecTable.applied(trees: output.inputWireSpecs))
    }
}

/// What a node's computation hands the writer: a run's output, whose trees are folded as
/// it is written, or a hit's, whose table is applied as it was stored.
enum ComputedOutput {
    case processed(ProcessOutput)
    case cached(AppliedOutput)
    /// The state an input stood in, published without a run (`stateStoppingProcess`):
    /// no key, no lookup and nothing stored.
    case stopped(ProcessOutput)
}
