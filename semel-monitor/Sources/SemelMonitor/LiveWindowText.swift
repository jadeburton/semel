// LiveWindowText.swift
// SemelMonitor
//
// The live window as `--print` writes it on `show`: its title, the counts, the bar as how
// many of the scheduled nodes have started, each running node with how long it has run,
// and the last settle's products — every folder of them, its rows as the products window
// writes them — and errors in the report's lines.
//
//     live: semel · idle
//       scheduled 3 · computed 3 · from cache 0 · errors 0
//       started 3 of 3
//       nothing running
//       last settle: 3 products appeared
//       c: config.txt · appeared
//       c: hello · appeared
//       c: hello.dylib · appeared

public enum LiveWindowText {

    public static func lines(for model: LiveWindowModel, at now: Duration) -> [String] {
        var body: [String] = []
        body += [model.countsLine].compactMap { $0 }
        body += [barLine(of: model)].compactMap { $0 }
        let running = model.runningRows(at: now)
        body += running.isEmpty ? ["nothing running"] : running.map(line(of:))
        body += [model.lastSettleLine].compactMap { $0 }
        if let products = model.lastSettle {
            body += productLines(of: products)
        }
        return ["live: \(model.title)"] + body.map { "  \($0)" }
    }

    /// `started 40 of 88`: the bar's two numbers, pending against scheduled.
    static func barLine(of model: LiveWindowModel) -> String? {
        if let progress = model.progress {
            return "started \(progress.scheduled - progress.pending) of \(progress.scheduled)"
        }
        return model.lastSettled.map { "started \($0.scheduled) of \($0.scheduled)" }
    }

    /// `SwiftCompiler · Models · 2.1 s`.
    static func line(of row: RunningNodeRow) -> String {
        ([row.type] + (row.name.isEmpty ? [] : [row.name]) + [ElapsedText.text(row.elapsed)]).joined(separator: " · ")
    }

    /// Each folder's rows under its title, `c: hello · changed`, without the sizes the
    /// events do not carry; then the settle's errors in the report's lines.
    static func productLines(of model: ProductsWindowModel) -> [String] {
        let rows = model.sections.flatMap { section -> [String] in
            guard case .folder(let folder) = section else {
                return []
            }
            let title = model.title(of: section)
            return model.rows(in: folder).map { row in
                "\(title): " + ([row.name] + [row.mark?.word].compactMap { $0 }).joined(separator: " · ")
            }
        }
        let errors = model.snapshot.errors.isEmpty ? [] : model.errorLines
        return rows + errors
    }
}
