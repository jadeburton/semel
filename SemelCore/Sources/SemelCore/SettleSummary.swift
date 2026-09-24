// SettleSummary.swift
// SemelCore
//
// What one settle did, in four numbers.
//
// A cache hit and a full recompute leave the same trace at the prompt — the same products,
// the same "no errors" — so the difference has to be counted where it happens and carried
// out. The engine accumulates these across every batch of one settle and hands them to
// `BuildEngine.settleReporter`; a server turns them into an event and the terminal turns
// them into a line.

/// The totals for one settle: everything between the engine leaving idle and reaching it
/// again, however many batches that took.
///
/// Every number counts *nodes*, each one once. A settle takes as many batches as the
/// cascade needs and one node can appear in several of them, so a node woken three times
/// is one scheduled node, and a node that ran in an early batch and hit the cache in a
/// later one is one node, counted by what it did last.
///
/// `scheduled` is therefore not `computed + fromCache`, and the gap is the nodes that did
/// neither: a node fetched as scheduled and then found to be waiting on an input that is
/// still pending or unreadable is unscheduled without producing an output, and something
/// downstream schedules it again later. Counting it under `scheduled` alone is the honest
/// answer — it was woken, and it did nothing.
public struct SettleSummary: Equatable, Sendable {

    /// Distinct nodes the engine fetched as scheduled.
    public var scheduled = 0

    /// Distinct nodes whose last result in this settle was one they ran themselves.
    public var computed = 0

    /// Distinct nodes whose last result in this settle came from a cache entry.
    public var fromCache = 0

    /// Errors the settle-time error report named, counted the way the `errors` command
    /// counts them — one per port carrying a message — so a summary and a report of the
    /// same failures say the same number.
    public var errors = 0

    public init(scheduled: Int = 0, computed: Int = 0, fromCache: Int = 0, errors: Int = 0) {
        self.scheduled = scheduled
        self.computed  = computed
        self.fromCache = fromCache
        self.errors    = errors
    }
}
