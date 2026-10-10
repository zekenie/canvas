import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import Foundation
import LanguageModels
import SwiftUI
import TableOfContents
import TestKit

// The inspector's list, SwiftUI's `List` in an NSHostingView, replaced on a switch between boards of
// the board's worth of shapes each: from the switch to the new board's rows in the table. Reported
// against its target, not held to it (design §6), in its own file since it needs SwiftUI. And a
// crumb's menu over the root's rows, from its showing to its rows in the window: reported.

@MainActor let inspectorBenchmarks = Suite("Inspector benchmarks", [
    test("the inspector's list is replaced on a switch between boards of the board's worth of shapes") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            let file = generatedFile(root: size, children: [size])
            let owner = try require(owners(in: file).first)
            // As the app places it: the detail panel, which shows the table of contents with
            // nothing selected, about the panel's width, with real time for SwiftUI's updates.
            let editor = CanvasEditor(registry: registry, file: file, scheduler: TaskScheduler())
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 260, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            let hosting = NSHostingView(rootView: ShippedPlugins.detailPanel(editor: editor, onExit: {}))
            hosting.frame = CGRect(x: 0, y: 0, width: 260, height: 700)
            window.contentView = hosting
            // The table's rows, less its header, and those it should show for the board shown: one
            // for each shape that isn't nested (an arrow is under its note, folded).
            let rows = { max(0, (hosting.descendants(NSTableView.self).first?.numberOfRows ?? 0) - 1) }
            let contents = try require(editor.tableOfContents)
            let listed = { contents.entries.count }
            let clock = ContinuousClock()
            var first = 0.0, down = 0.0, up = 0.0
            // AppKit logs its reentrancy warning when a list first shows 200 rows or more: counted.
            let logged = standardError {
                first = clock.measure { window.spin(until: { rows() == listed() }, timeout: 60) }.milliseconds
                down = clock.measure {
                    editor.showBoard(BoardID(owner: owner))
                    window.spin(until: { rows() == listed() }, timeout: 60)
                }.milliseconds
                up = clock.measure {
                    editor.showBoard(.root)
                    window.spin(until: { rows() == listed() }, timeout: 60)
                }.milliseconds
            }
            expect(editor.board.isRoot && rows() > 0, "the root's rows are shown")
            let warnings = logged.components(separatedBy: tableReentrancyWarning).count - 1
            report(String(format: "%6d shapes on each board: the inspector's list first shown %.0f ms; replaced going into the subboard %.0f ms, back up %.0f ms (target %.0f, reported); AppKit's reentrancy warning logged %d times",
                          size, first, down, up, Budget.listReplacedTarget, warnings))
        }
    },
    test("the root crumb's menu over the root's rows, in the window: from its showing to its rows there") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            let file = generatedFile(root: size, children: [size])
            let child = BoardID(owner: try require(owners(in: file).first))
            // The editor's clock is the test's, so the menu shows the moment the test says; SwiftUI's
            // updates land as the main run loop runs.
            let h = EditorHarness { CanvasEditor(registry: registry, file: file, showing: child, scheduler: $0) }
            let size800 = CGRect(x: 0, y: 0, width: 1200, height: 800)
            let window = NSWindow(contentRect: size800, styleMask: [.titled], backing: .buffered, defer: false)
            let hosting = NSHostingView(rootView: ShippedPlugins.boardPath(editor: h.editor))
            hosting.sizingOptions = []
            hosting.frame = size800
            window.contentView = hosting
            // Buttons below the pill (8 points down, some 26 tall): the menu's rows.
            let rows = {
                hosting.descendants(NSButton.self).filter { button in
                    let frame = hosting.convert(button.bounds, from: button)
                    return (hosting.isFlipped ? frame.minY : hosting.bounds.height - frame.maxY) > 40
                }.count
            }
            window.spin(until: { !hosting.descendants(NSButton.self).isEmpty }, timeout: 10)
            let crumbs = try require(h.editor.boardCrumbs)
            let clock = ContinuousClock()
            // Its first showing makes the root's rows; the next takes them back.
            var shown: [Double] = []
            for _ in 0..<2 {
                crumbs.pointerEntered(crumb: .root)
                shown.append(clock.measure {
                    h.wait(150)
                    window.spin(until: { rows() > 0 }, timeout: 10)
                }.milliseconds)
                crumbs.closeMenu()
                window.spin(until: { rows() == 0 }, timeout: 10)
            }
            report(String(format: "%6d shapes on the root, inside its subboard: a crumb's menu of the root's rows in the window %.0f ms the first time, %.0f again (reported)",
                          size, shown[0], shown[1]))
        }
    },
])
