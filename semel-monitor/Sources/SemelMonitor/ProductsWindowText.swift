// ProductsWindowText.swift
// SemelMonitor
//
// The products window as `--print` writes it when the window would open: what it opened
// for, the left column with the selected section in brackets, then that section's rows —
// a product's name, its mark and its size — or the error report's lines.
//
//     window: 2 products changed
//       output: · [c] · Errors (0)
//       config.txt · 23 bytes
//       hello · changed · 33 KB
//       hello.dylib · changed · 33 KB

public enum ProductsWindowText {

    /// The window opened for `card`, a click's, or for *Products…* when nil.
    public static func lines(for model: ProductsWindowModel, openedFor card: Card?) -> [String] {
        let opened  = card.map(CardText.headline(of:)) ?? "products"
        let column  = model.sections.map { section in
            section == model.section ? "[\(model.title(of: section))]" : model.title(of: section)
        }
        let content: [String]
        switch model.section {
        case .folder:
            let rows = model.rows
            content = rows.isEmpty ? ["(empty)"] : rows.map(line(of:))
        case .errors:
            content = model.errorLines
        }
        return ["window: \(opened)", "  " + column.joined(separator: " · ")] + content.map { "  \($0)" }
    }

    /// The window could not be filled: the engine is not there to list `output:`.
    public static func lines(failing reason: String, openedFor card: Card?) -> [String] {
        ["window: \(card.map(CardText.headline(of:)) ?? "products")", "  \(reason)"]
    }

    static func line(of row: ProductRow) -> String {
        ([row.name] + [row.mark?.word].compactMap { $0 } + [row.sizeText]).joined(separator: " · ")
    }
}
