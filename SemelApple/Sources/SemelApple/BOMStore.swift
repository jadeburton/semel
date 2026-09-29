//
//  BOMStore.swift
//  SemelApple
//
//  The container an `Assets.car` is written in: Apple's undocumented BOM store, read and
//  written for exactly what `AssetCatalogCanonicaliser` needs and nothing more.
//
//  A store is numbered blocks of bytes. A 512-byte header names two tables near the end of
//  the file: the block table, each block's address and length by index, and the variables,
//  each a name and the index of its block. A variable's block is either data of its own
//  (`CARHEADER`, `KEYFORMAT`, …) or the header of a B+ tree (`RENDITIONS`, `FACETKEYS`,
//  `APPEARANCEKEYS`, …) whose nodes, keys and values are blocks too. Every number in the
//  container is big-endian; what the blocks hold is the catalog's business, and CoreUI
//  writes that little-endian.
//
//  Which index a block gets is the order actool happened to allocate it in, and that order
//  is not a function of the catalog (B-89): two compiles of one catalog can give its two
//  appearance names each other's blocks. So the canonical form renumbers every block in
//  the order a walk from the variables first reaches it, and lays the blocks out in that
//  order. Nothing reaches a block except through a variable, a tree header, or a tree node,
//  so those are the only places an index is rewritten, and a block no walk reaches is an
//  error rather than something quietly dropped.
//

import Foundation

// MARK: - Errors

enum BOMStoreError: Error, CustomStringConvertible, Equatable {
    case notABOMStore
    case unsupportedVersion(UInt32)
    case truncated(what: String)
    case blockOutOfRange(index: UInt32)
    case emptyBlockReferenced(index: UInt32, by: String)
    case unreachableBlocks([UInt32])
    case treeCycle(variable: String, node: UInt32)
    case unknownKeyForm(variable: String, form: UInt8)

    var description: String {
        switch self {
        case .notABOMStore:
            return "it does not open with 'BOMStore'"
        case .unsupportedVersion(let version):
            return "its BOM store is version \(version), and only version 1 is known"
        case .truncated(let what):
            return "its \(what) runs past the end of the file"
        case .blockOutOfRange(let index):
            return "it refers to block \(index), past the end of its block table"
        case .emptyBlockReferenced(let index, let referrer):
            return "\(referrer) refers to block \(index), which is empty"
        case .unreachableBlocks(let indices):
            let shown = indices.prefix(10).map(String.init).joined(separator: ", ")
            return "blocks \(shown)\(indices.count > 10 ? ", …" : "") are reached from no variable, and what they hold is unknown"
        case .treeCycle(let variable, let node):
            return "the tree of \(variable) reaches its node \(node) twice"
        case .unknownKeyForm(let variable, let form):
            return "the tree of \(variable) declares key form \(form); only 0 (a key block) and 1 (a key in the entry) are known"
        }
    }
}

// MARK: - Store

struct BOMStore: Equatable {

    struct Variable: Equatable {
        let name: String
        var block: UInt32
    }

    /// Block contents by index. Index 0 is the null block, and an index with no address and
    /// no length holds nothing; both are nil.
    var blocks: [[UInt8]?]
    /// In the order the file lists them, which is the order CoreUI writes them in: kept,
    /// since nothing has shown it to vary.
    var variables: [Variable]

    static let magic = Array("BOMStore".utf8)
    static let headerSize = 512
    /// Where actool puts every block, the variables and the block table: at a multiple of
    /// sixteen, the gap zero-filled. Kept, because a reader may map a rendition's pixels in
    /// place.
    static let alignment = 16

    init(blocks: [[UInt8]?], variables: [Variable]) {
        self.blocks    = blocks
        self.variables = variables
    }

    init(bytes: [UInt8]) throws {
        guard bytes.count >= 32, Array(bytes[0..<8]) == Self.magic else {
            throw BOMStoreError.notABOMStore
        }
        let version = bytes.bigEndianUInt32(at: 8)
        guard version == 1 else {
            throw BOMStoreError.unsupportedVersion(version)
        }
        let tableOffset     = Int(bytes.bigEndianUInt32(at: 16))
        let variablesOffset = Int(bytes.bigEndianUInt32(at: 24))

        guard tableOffset + 4 <= bytes.count else {
            throw BOMStoreError.truncated(what: "block table")
        }
        let capacity = Int(bytes.bigEndianUInt32(at: tableOffset))
        guard tableOffset + 4 + capacity * 8 <= bytes.count else {
            throw BOMStoreError.truncated(what: "block table")
        }
        var blocks: [[UInt8]?] = []
        blocks.reserveCapacity(capacity)
        for index in 0..<capacity {
            let entry   = tableOffset + 4 + index * 8
            let address = Int(bytes.bigEndianUInt32(at: entry))
            let length  = Int(bytes.bigEndianUInt32(at: entry + 4))
            guard index != 0, address != 0 || length != 0 else {
                blocks.append(nil)
                continue
            }
            guard address + length <= bytes.count else {
                throw BOMStoreError.truncated(what: "block \(index)")
            }
            blocks.append(Array(bytes[address..<(address + length)]))
        }

        guard variablesOffset + 4 <= bytes.count else {
            throw BOMStoreError.truncated(what: "variable table")
        }
        let variableCount = Int(bytes.bigEndianUInt32(at: variablesOffset))
        var position = variablesOffset + 4
        var variables: [Variable] = []
        for _ in 0..<variableCount {
            guard position + 5 <= bytes.count else {
                throw BOMStoreError.truncated(what: "variable table")
            }
            let block      = bytes.bigEndianUInt32(at: position)
            let nameLength = Int(bytes[position + 4])
            guard position + 5 + nameLength <= bytes.count else {
                throw BOMStoreError.truncated(what: "variable table")
            }
            let name = String(decoding: bytes[(position + 5)..<(position + 5 + nameLength)], as: UTF8.self)
            variables.append(Variable(name: name, block: block))
            position += 5 + nameLength
        }

        self.blocks    = blocks
        self.variables = variables
    }

    func block(_ index: UInt32, referredToBy referrer: String) throws -> [UInt8] {
        guard Int(index) < blocks.count else {
            throw BOMStoreError.blockOutOfRange(index: index)
        }
        guard let content = blocks[Int(index)] else {
            throw BOMStoreError.emptyBlockReferenced(index: index, by: referrer)
        }
        return content
    }

    func variable(named name: String) -> Variable? {
        variables.first { $0.name == name }
    }

    // MARK: Canonical numbering

    /// The same store with every block renumbered in the order a walk from the variables
    /// first reaches it: a variable's block; for a tree, its header, then each node depth
    /// first, a leaf's entries key before value, a branch's children in order and its
    /// separator keys after them (they are the same blocks as the leaves' keys). Every
    /// index in a variable, a tree header or a node is rewritten to match; the contents of
    /// a block are otherwise its own.
    func canonicallyNumbered() throws -> BOMStore {
        var order: [UInt32] = []
        var newIndex: [UInt32: UInt32] = [:]
        /// A block whose indices the renumbering rewrites: a tree's header or one of its nodes.
        struct IndexHolder {
            let variable: String
            let index: UInt32
            let keysAreBlocks: Bool
        }
        var trees: [IndexHolder] = []
        var nodes: [IndexHolder] = []

        func reach(_ index: UInt32, from referrer: String) throws {
            guard index != 0, newIndex[index] == nil else {
                return
            }
            _ = try block(index, referredToBy: referrer)
            order.append(index)
            newIndex[index] = UInt32(order.count)
        }

        for variable in variables {
            try reach(variable.block, from: "variable \(variable.name)")
            guard let tree = try BOMTree(store: self, variable: variable) else {
                continue
            }
            trees.append(IndexHolder(variable: variable.name, index: variable.block, keysAreBlocks: tree.keysAreBlocks))
            var visited = Set<UInt32>()
            func walk(_ nodeIndex: UInt32) throws {
                guard visited.insert(nodeIndex).inserted else {
                    throw BOMStoreError.treeCycle(variable: variable.name, node: nodeIndex)
                }
                try reach(nodeIndex, from: "the tree of \(variable.name)")
                nodes.append(IndexHolder(variable: variable.name, index: nodeIndex, keysAreBlocks: tree.keysAreBlocks))
                let node = try BOMTreeNode(bytes: try block(nodeIndex, referredToBy: "the tree of \(variable.name)"),
                                           variable: variable.name)
                for entry in node.entries {
                    if node.isLeaf {
                        if tree.keysAreBlocks {
                            try reach(entry.key, from: "a key of \(variable.name)")
                        }
                        try reach(entry.valueOrChild, from: "a value of \(variable.name)")
                    } else {
                        try walk(entry.valueOrChild)
                        if tree.keysAreBlocks {
                            try reach(entry.key, from: "a key of \(variable.name)")
                        }
                    }
                }
                if let trailingChild = node.trailingChild {
                    try walk(trailingChild)
                }
            }
            try walk(tree.root)
        }

        let unreachable = blocks.indices.filter { blocks[$0] != nil && newIndex[UInt32($0)] == nil }.map(UInt32.init)
        guard unreachable.isEmpty else {
            throw BOMStoreError.unreachableBlocks(unreachable)
        }

        func renumbered(_ index: UInt32) -> UInt32 {
            index == 0 ? 0 : newIndex[index] ?? 0
        }

        var rewritten: [UInt32: [UInt8]] = [:]
        for tree in trees {
            var bytes = try block(tree.index, referredToBy: "the tree of \(tree.variable)")
            bytes.setBigEndianUInt32(renumbered(bytes.bigEndianUInt32(at: BOMTree.rootOffset)), at: BOMTree.rootOffset)
            rewritten[tree.index] = bytes
        }
        for holder in nodes {
            var bytes = try block(holder.index, referredToBy: "the tree of \(holder.variable)")
            let node  = try BOMTreeNode(bytes: bytes, variable: holder.variable)
            bytes.setBigEndianUInt32(renumbered(node.forward), at: BOMTreeNode.forwardOffset)
            bytes.setBigEndianUInt32(renumbered(node.backward), at: BOMTreeNode.backwardOffset)
            for (position, entry) in node.entries.enumerated() {
                let offset = BOMTreeNode.entriesOffset + position * BOMTreeNode.entrySize
                bytes.setBigEndianUInt32(renumbered(entry.valueOrChild), at: offset)
                if holder.keysAreBlocks {
                    bytes.setBigEndianUInt32(renumbered(entry.key), at: offset + 4)
                }
            }
            if let trailingChild = node.trailingChild {
                bytes.setBigEndianUInt32(renumbered(trailingChild),
                                         at: BOMTreeNode.entriesOffset + node.entries.count * BOMTreeNode.entrySize)
            }
            rewritten[holder.index] = bytes
        }

        var newBlocks: [[UInt8]?] = [nil]
        for index in order {
            newBlocks.append(try rewritten[index] ?? block(index, referredToBy: "the walk"))
        }
        let newVariables = variables.map { Variable(name: $0.name, block: renumbered($0.block)) }
        return BOMStore(blocks: newBlocks, variables: newVariables)
    }

    // MARK: Content without numbering

    /// One variable as it reads with every block index taken out: its block (a tree's root
    /// blanked), each node of a tree in walk order with its indices blanked, and each leaf
    /// entry's key and value bytes. Two stores whose views are equal hold the same catalog
    /// however their blocks are numbered.
    struct LogicalVariable: Equatable {
        let name: String
        let data: [UInt8]
        let nodes: [[UInt8]]
        let entries: [LogicalEntry]
    }

    struct LogicalEntry: Equatable {
        /// The key's block, or the key itself as four big-endian bytes.
        let key: [UInt8]
        let value: [UInt8]
    }

    func logicalView() throws -> [LogicalVariable] {
        try variables.map { variable in
            var data = try block(variable.block, referredToBy: "variable \(variable.name)")
            guard let tree = try BOMTree(store: self, variable: variable) else {
                return LogicalVariable(name: variable.name, data: data, nodes: [], entries: [])
            }
            data.setBigEndianUInt32(0, at: BOMTree.rootOffset)
            var nodes: [[UInt8]] = []
            var entries: [LogicalEntry] = []
            for numbered in try BOMTree.nodes(store: self, variable: variable) {
                let node  = numbered.node
                var bytes = try block(numbered.index, referredToBy: "the tree of \(variable.name)")
                bytes.setBigEndianUInt32(0, at: BOMTreeNode.forwardOffset)
                bytes.setBigEndianUInt32(0, at: BOMTreeNode.backwardOffset)
                for position in node.entries.indices {
                    let offset = BOMTreeNode.entriesOffset + position * BOMTreeNode.entrySize
                    bytes.setBigEndianUInt32(0, at: offset)
                    if tree.keysAreBlocks {
                        bytes.setBigEndianUInt32(0, at: offset + 4)
                    }
                }
                if node.trailingChild != nil {
                    bytes.setBigEndianUInt32(0, at: BOMTreeNode.entriesOffset + node.entries.count * BOMTreeNode.entrySize)
                }
                nodes.append(bytes)
                guard node.isLeaf else {
                    continue
                }
                for entry in node.entries {
                    var inlineKey: [UInt8] = []
                    inlineKey.appendBigEndianUInt32(entry.key)
                    let key = tree.keysAreBlocks ? try block(entry.key, referredToBy: "a key of \(variable.name)") : inlineKey
                    entries.append(LogicalEntry(key: key, value: try block(entry.valueOrChild, referredToBy: "a value of \(variable.name)")))
                }
            }
            return LogicalVariable(name: variable.name, data: data, nodes: nodes, entries: entries)
        }
    }

    // MARK: Writing

    /// The file: the header, every block in index order, the variables, the block table,
    /// each at a multiple of `alignment` — the layout actool writes, with nothing in it
    /// that depends on anything but the blocks. The block table has exactly one entry per
    /// index and an empty free list.
    func serialised() -> [UInt8] {
        var output = [UInt8](repeating: 0, count: Self.headerSize)
        var table: [(address: UInt32, length: UInt32)] = []
        for content in blocks {
            guard let content else {
                table.append((0, 0))
                continue
            }
            output.padToMultiple(of: Self.alignment)
            table.append((UInt32(output.count), UInt32(content.count)))
            output += content
        }

        output.padToMultiple(of: Self.alignment)
        let variablesOffset = output.count
        output.appendBigEndianUInt32(UInt32(variables.count))
        for variable in variables {
            let name = Array(variable.name.utf8)
            output.appendBigEndianUInt32(variable.block)
            output.append(UInt8(name.count))
            output += name
        }
        let variablesLength = output.count - variablesOffset

        output.padToMultiple(of: Self.alignment)
        let tableOffset = output.count
        output.appendBigEndianUInt32(UInt32(table.count))
        for entry in table {
            output.appendBigEndianUInt32(entry.address)
            output.appendBigEndianUInt32(entry.length)
        }
        // The free list: no entries, and the room for two that actool leaves after it.
        output.appendBigEndianUInt32(0)
        output += [UInt8](repeating: 0, count: 16)
        let tableLength = output.count - tableOffset

        var header = Self.magic
        header.appendBigEndianUInt32(1)
        header.appendBigEndianUInt32(UInt32(blocks.filter { $0 != nil }.count))
        header.appendBigEndianUInt32(UInt32(tableOffset))
        header.appendBigEndianUInt32(UInt32(tableLength))
        header.appendBigEndianUInt32(UInt32(variablesOffset))
        header.appendBigEndianUInt32(UInt32(variablesLength))
        output.replaceSubrange(0..<header.count, with: header)
        return output
    }
}

// MARK: - Trees

/// A variable's block that is a tree: `tree`, a version, the root node's block, the node
/// size, the entry count, and a byte saying where a key lives. The eight bytes after that
/// are the tree's own business — `RENDITIONS` keeps its key length there — and are kept.
struct BOMTree {
    let root: UInt32
    /// Whether an entry's key is the index of a block holding it (form 0) or the key
    /// itself, a number (form 1, as in `BITMAPKEYS`).
    let keysAreBlocks: Bool

    static let magic = Array("tree".utf8)
    static let rootOffset = 8
    static let keyFormOffset = 20

    /// Nil for a variable whose block is not a tree.
    init?(store: BOMStore, variable: BOMStore.Variable) throws {
        let bytes = try store.block(variable.block, referredToBy: "variable \(variable.name)")
        guard bytes.count >= Self.keyFormOffset + 1, Array(bytes[0..<4]) == Self.magic else {
            return nil
        }
        root = bytes.bigEndianUInt32(at: Self.rootOffset)
        let form = bytes[Self.keyFormOffset]
        guard form <= 1 else {
            throw BOMStoreError.unknownKeyForm(variable: variable.name, form: form)
        }
        keysAreBlocks = form == 0
    }

    struct NumberedNode {
        let index: UInt32
        let node: BOMTreeNode
    }

    /// Every node of the variable's tree, depth first, a branch's children left to right;
    /// none for a variable that is not a tree.
    static func nodes(store: BOMStore, variable: BOMStore.Variable) throws -> [NumberedNode] {
        guard let tree = try BOMTree(store: store, variable: variable) else {
            return []
        }
        var nodes: [NumberedNode] = []
        var visited = Set<UInt32>()
        func walk(_ nodeIndex: UInt32) throws {
            guard visited.insert(nodeIndex).inserted else {
                throw BOMStoreError.treeCycle(variable: variable.name, node: nodeIndex)
            }
            let node = try BOMTreeNode(bytes: try store.block(nodeIndex, referredToBy: "the tree of \(variable.name)"),
                                       variable: variable.name)
            nodes.append(NumberedNode(index: nodeIndex, node: node))
            guard !node.isLeaf else {
                return
            }
            for entry in node.entries {
                try walk(entry.valueOrChild)
            }
            if let trailingChild = node.trailingChild {
                try walk(trailingChild)
            }
        }
        try walk(tree.root)
        return nodes
    }

    /// Every leaf entry in order, left to right: a key (a block index or the key itself)
    /// and a value's block.
    static func leafEntries(store: BOMStore, variable: BOMStore.Variable) throws -> [BOMTreeNode.Entry] {
        try nodes(store: store, variable: variable).filter(\.node.isLeaf).flatMap(\.node.entries)
    }
}

/// One node of a tree: whether it is a leaf, how many entries, the next and previous leaf,
/// then the entries — a leaf's a value and a key, a branch's a child and the separator key
/// that is its child's last. A branch has one child more than it has separators, after the
/// entries. What follows is the node's own business (a `RENDITIONS` node repeats its keys
/// there) and is kept as it is.
struct BOMTreeNode {
    struct Entry: Equatable {
        let valueOrChild: UInt32
        let key: UInt32
    }

    let isLeaf: Bool
    let entries: [Entry]
    let forward: UInt32
    let backward: UInt32
    let trailingChild: UInt32?

    static let forwardOffset  = 4
    static let backwardOffset = 8
    static let entriesOffset  = 12
    static let entrySize      = 8

    init(bytes: [UInt8], variable: String) throws {
        guard bytes.count >= Self.entriesOffset else {
            throw BOMStoreError.truncated(what: "tree node of \(variable)")
        }
        isLeaf       = bytes.bigEndianUInt16(at: 0) != 0
        let count    = Int(bytes.bigEndianUInt16(at: 2))
        forward      = bytes.bigEndianUInt32(at: Self.forwardOffset)
        backward     = bytes.bigEndianUInt32(at: Self.backwardOffset)
        let end      = Self.entriesOffset + count * Self.entrySize + (isLeaf ? 0 : 4)
        guard end <= bytes.count else {
            throw BOMStoreError.truncated(what: "tree node of \(variable)")
        }
        entries = (0..<count).map { position in
            let offset = Self.entriesOffset + position * Self.entrySize
            return Entry(valueOrChild: bytes.bigEndianUInt32(at: offset), key: bytes.bigEndianUInt32(at: offset + 4))
        }
        trailingChild = isLeaf ? nil : bytes.bigEndianUInt32(at: Self.entriesOffset + count * Self.entrySize)
    }
}

// MARK: - Bytes

extension Array where Element == UInt8 {
    func bigEndianUInt32(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func bigEndianUInt16(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    mutating func setBigEndianUInt32(_ value: UInt32, at offset: Int) {
        for position in 0..<4 {
            self[offset + position] = UInt8(truncatingIfNeeded: value >> (24 - 8 * position))
        }
    }

    mutating func setLittleEndianUInt16(_ value: UInt16, at offset: Int) {
        self[offset]     = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    mutating func appendBigEndianUInt32(_ value: UInt32) {
        for position in 0..<4 {
            append(UInt8(truncatingIfNeeded: value >> (24 - 8 * position)))
        }
    }

    mutating func padToMultiple(of alignment: Int) {
        let remainder = count % alignment
        if remainder != 0 {
            append(contentsOf: [UInt8](repeating: 0, count: alignment - remainder))
        }
    }
}
