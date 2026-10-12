// ExportPanel.swift
// semel-monitor
//
// The standard save panel an export asks for its destination with, and the line the
// window says afterwards. The folder chosen is `export`'s `--into`: created when it is not
// there, written into when it is, never emptied first — as the command does.

import AppKit
import SemelMonitor

enum ExportPanel {

    static func run(_ request: ExportRequest, over window: NSWindow, then export: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.title                = "Export"
        panel.prompt               = "Export"
        panel.message              = "The folder to write the products into, keeping their tree below the folder they are in."
        panel.nameFieldLabel       = "Folder:"
        panel.nameFieldStringValue = request.suggestedName
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else {
                return
            }
            export(destination.path)
        }
    }

    /// `Exported 3 files into /Users/…/c`, with what `export` reported on the way after it;
    /// or what stopped it.
    static func outcome(of result: Result<ExportResult, Error>, into destination: String) -> String {
        switch result {
        case .failure(let error):
            return "Not exported: \(error)"
        case .success(let exportResult):
            guard let written = exportResult.written else {
                return exportResult.messages.last ?? "Nothing to export."
            }
            let line = "Exported \(written) \(written == 1 ? "file" : "files") into \(destination)"
            return ([line] + exportResult.messages).joined(separator: " · ")
        }
    }
}

/// The main menu of an accessory, never shown: what routes the key equivalents of the
/// products window — copy and select all in the errors, close.
enum MainMenu {

    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("semel-monitor", [
            NSMenuItem(title: "Quit semel-monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]))
        main.addItem(submenu("Edit", [
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]))
        main.addItem(submenu("Window", [
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ]))
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
