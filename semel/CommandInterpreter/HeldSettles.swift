// HeldSettles.swift
// semel
//
// What a `build` holds of its settles until its waits are over (B-110, B-129).

/// The settles of one `build`, held rather than printed while it runs and printed as one
/// report at its end: the work summed over them, the errors of the last — which is the
/// verdict — and what they did to the products, under that line. A settle the follow loop
/// answers by pushing what it named would otherwise print a failing line just before the
/// push that fixes it.
///
/// The artifact diff is held with the summary rather than printed as its settle ends. Its
/// lines are indented because they belong to the summary above them; printed as they
/// came, they would land under whatever the build printed last, a `Push file:` line, with
/// the summary they belong to after `Settled.` further down.
struct HeldSettles {
    private var scheduled = 0
    private var computed  = 0
    private var fromCache = 0
    private var errors    = 0
    private var artifacts = NetArtifactChanges()

    mutating func add(scheduled: Int, computed: Int, fromCache: Int, errors: Int) {
        self.scheduled += scheduled
        self.computed  += computed
        self.fromCache += fromCache
        self.errors     = errors
    }

    mutating func add(appeared: [String], changed: [String], disappeared: [String]) {
        artifacts.add(appeared: appeared, changed: changed, disappeared: disappeared)
    }

    /// The summary, when any held settle did work, and the artifact diff under it.
    var lines: [String] {
        let summary = SettleSummaryRenderer.line(scheduled: scheduled, computed: computed,
                                                 fromCache: fromCache, errors: errors)
        let net = artifacts.net
        return (summary.map { [$0] } ?? [])
            + ArtifactChangeRenderer.lines(appeared: net.appeared, changed: net.changed, disappeared: net.disappeared)
    }
}

/// Several settles' artifact diffs as one: what they did to each product between the
/// start of the first and the end of the last. A settle names a path under one kind at
/// most; across settles, the first kind a path was named under says whether the reader
/// had that product before, and the last whether they have it now.
struct NetArtifactChanges {
    private enum Kind {
        case appeared, changed, disappeared
    }

    private var kindsByPath: [String: (first: Kind, last: Kind)] = [:]

    mutating func add(appeared: [String], changed: [String], disappeared: [String]) {
        record(appeared,    as: .appeared)
        record(changed,     as: .changed)
        record(disappeared, as: .disappeared)
    }

    private mutating func record(_ paths: [String], as kind: Kind) {
        for path in paths {
            kindsByPath[path] = (first: kindsByPath[path]?.first ?? kind, last: kind)
        }
    }

    /// Each list in path order, as a settle's own are. A product new to these settles
    /// that went again is not news. One that went and came back is `changed`: the client
    /// sees no hashes, so it cannot tell a product rebuilt to the bytes it had from one
    /// rebuilt to others, and saying nothing would hide the second.
    var net: (appeared: [String], changed: [String], disappeared: [String]) {
        var appeared:    [String] = []
        var changed:     [String] = []
        var disappeared: [String] = []
        for (path, kinds) in kindsByPath.sorted(by: { $0.key < $1.key }) {
            switch (kinds.first, kinds.last) {
            case (.appeared, .disappeared): continue
            case (.appeared, _):            appeared.append(path)
            case (_, .disappeared):         disappeared.append(path)
            default:                        changed.append(path)
            }
        }
        return (appeared, changed, disappeared)
    }
}
