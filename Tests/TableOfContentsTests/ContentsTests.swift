import AppKit
import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Keyboard
import Selection
import SwiftUI
import TableOfContents
import TestKit

@MainActor let contentsTests = Suite("Table of contents: rows", [
    test("lists every shape in document order, back to front, each with its kind's row") {
        let editor = try contentsEditor()
        editor.add(Widget(name: "First"))
        editor.add(Box(widgetFrame))
        editor.add(Widget(name: "Last", count: 3))
        let entries = editor.contents.entries
        expectEqual(entries.outline, ["First", "box", "Last"])
        expectEqual(entries.map(\.kind), [Widget.kind, Box.kind, Widget.kind])
        expectEqual(entries.last?.label?.badge, "3")
        expect(entries.allSatisfy { $0.children == nil }, "nothing nests: no disclosure triangles")
    },
    test("a kind with no row is listed by the label and symbol of the tool that places it, else by its kind") {
        let editor = try contentsEditor()
        editor.add(Gizmo())
        editor.add(Disc(widgetFrame))
        let entries = editor.contents.entries
        expectEqual(entries.outline, ["Gizmo", "disc"])
        expectEqual(entries.map(\.symbol), ["cube", "square.dashed"])
        expectEqual(entries.map { $0.label?.systemImage }, [nil, nil], "a label without a symbol shows its kind's")
    },
    test("a row's symbol is its tool's unless the row gives one") {
        let editor = try contentsEditor()
        let widget = editor.add(Widget(name: "W"))
        editor.add(Pin("P", on: nil))
        let entries = editor.contents.entries
        expectEqual(entries.map(\.symbol), ["gearshape", "square.dashed"])
        expectEqual(entries.map { $0.label?.systemImage }, [nil, "pin"])
        expectEqual(entries.first?.id, widget)
    },
    test("a title is one line; a blank one shows the placeholder, dimmed") {
        let label = ContentsLabel("  Buy\n\nmilk\tand  eggs ", placeholder: "Empty")
        expectEqual(label.text, "Buy milk and eggs")
        expect(!label.isPlaceholder)
        let blank = ContentsLabel(" \n ", placeholder: "Empty")
        expectEqual(blank.text, "Empty")
        expect(blank.isPlaceholder)
        let bare = ContentsLabel("")
        expectEqual(bare.text, "")
        expect(!bare.isPlaceholder, "no placeholder to show")
    },
    test("a row's tooltip is its text, for a row cut short, to 200 characters cut between words; a placeholder, or no text, has none") {
        let long = "TODO: " + String(repeating: "and then something else ", count: 8)
        expectEqual(ContentsLabel(long).help, long.split(whereSeparator: \.isWhitespace).joined(separator: " "), "on one line, as the row reads")
        let page = String(repeating: "a pasted paragraph goes on\n", count: 40)
        let folded = page.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let help = try require(ContentsLabel(page).help)
        expect(help.hasSuffix("…") && help.count <= 201, "cut: \(help.count)")
        let kept = String(help.dropLast())
        expect(folded.hasPrefix(kept + " "), "between words, the last one whole: \(kept.suffix(20))")
        expect(kept.count > 180, "as much as fits")
        let exact = String(repeating: "abcd ", count: 40) + "end"             // a space right at the 200th character
        expectEqual(ContentsLabel(exact).help, String(repeating: "abcd ", count: 40).dropLast() + "…")
        expectEqual(ContentsLabel("  Buy\nmilk ", placeholder: "Empty").help, "Buy milk")
        expectEqual(ContentsLabel(" ", placeholder: "Empty").help, nil)
        expectEqual(ContentsLabel("").help, nil)
    },
    test("a stand-in's row has an arrow cut into its symbol's bottom-leading corner, in its title's color, and is otherwise as it was") {
        /// The label alone in an unshown window, as the list lays out its row: symbol, then title.
        @MainActor func render(_ label: ContentsLabel) -> NSBitmapImageRep {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 24), styleMask: [.titled], backing: .buffered, defer: false)
            let hosting = NSHostingView(rootView: label.padding(.leading, 8).frame(width: 160, height: 24, alignment: .leading))
            hosting.frame = CGRect(x: 0, y: 0, width: 160, height: 24)
            window.contentView = hosting
            window.settle()
            return snapshot(hosting)
        }
        /// The points where two renders differ.
        @MainActor func changes(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [CGPoint] {
            (0..<24).flatMap { y in (0..<160).compactMap { x in
                pixel(a, at: CGPoint(x: x, y: y)) != pixel(b, at: CGPoint(x: x, y: y)) ? CGPoint(x: x, y: y) : nil
            } }
        }
        /// The most any of `points` stands off the background (a corner far from the label), in gray.
        @MainActor func contrast(_ rep: NSBitmapImageRep, at points: [CGPoint]) -> Int {
            func gray(_ point: CGPoint) -> Int { pixel(rep, at: point).prefix(3).reduce(0, +) / 3 }
            let background = gray(CGPoint(x: 155, y: 2))
            return points.map { abs(gray($0) - background) }.max() ?? 0
        }
        expect(!ContentsLabel("Ports").standsIn, "none by default")
        let plain = render(ContentsLabel("Ports", systemImage: "note.text", color: .yellow))
        let standIn = render(ContentsLabel("Ports", systemImage: "note.text", color: .yellow, standsIn: true))
        // Where the symbol's ink is, from a render without it, and where the title starts, from one
        // with other letters (no title at all would move the symbol).
        let symbol = changes(plain, render(ContentsLabel("Ports", systemImage: "note.text", color: .clear)))
        let title = changes(plain, render(ContentsLabel("Mmmmm", systemImage: "note.text", color: .yellow)))
        let symbolLeft = try require(symbol.map(\.x).min())
        let symbolTop = try require(symbol.map(\.y).min()), symbolBottom = try require(symbol.map(\.y).max())
        let titleLeft = try require(title.map(\.x).min())

        let arrow = changes(plain, standIn)
        expect(arrow.count > 10, "the arrow shows: \(arrow.count) points")
        expect(arrow.allSatisfy { $0.x < titleLeft }, "only at the symbol, the title untouched")
        expect(try require(arrow.map(\.x).min()) <= symbolLeft + 1, "at its leading side")
        let arrowTop = try require(arrow.map(\.y).min()), arrowBottom = try require(arrow.map(\.y).max())
        expect(arrowBottom >= symbolBottom && arrowTop > symbolTop + 2, "at its bottom: \(arrowTop)...\(arrowBottom)")

        let dimmedPlain = render(ContentsLabel("", placeholder: "Ports", systemImage: "note.text", color: .yellow))
        let dimmed = render(ContentsLabel("", placeholder: "Ports", systemImage: "note.text", color: .yellow, standsIn: true))
        let dimmedArrow = changes(dimmedPlain, dimmed)
        expect(dimmedArrow.allSatisfy { $0.x < titleLeft }, "a placeholder's arrow at the symbol too")
        expect(contrast(dimmed, at: dimmedArrow) + 30 < contrast(standIn, at: arrow),
               "dimmed with the placeholder: \(contrast(dimmed, at: dimmedArrow)) against \(contrast(standIn, at: arrow))")
    },
    test("`when` leaves shapes out of the list, and puts them back when it lets them in") {
        let editor = try contentsEditor()
        editor.add(Widget(name: "Shown"))
        let hidden = editor.add(Widget(name: "Hidden", isHidden: true))
        expectEqual(editor.contents.entries.outline, ["Shown"])
        editor.transact { $0.update(hidden, as: Widget.self) { $0.props.isHidden = false } }
        expectEqual(editor.contents.entries.outline, ["Shown", "Hidden"])
    },
    test("`nestedUnder` puts a row under the shape it names, in document order") {
        let editor = try contentsEditor()
        let board = editor.add(Widget(name: "Board"))
        editor.add(Pin("first pin", on: board))
        editor.add(Widget(name: "Other"))
        editor.add(Pin("second pin", on: board))
        let entries = editor.contents.entries
        expectEqual(entries.outline, ["Board", "  first pin", "  second pin", "Other"])
        expectEqual(entries.first?.children?.count, 2)
        expectEqual(entries.last?.children == nil, true)
    },
    test("a kind can nest without a row of its own, keeping its tool's label and symbol") {
        let editor = try contentsEditor()
        let board = editor.add(Widget(name: "Board"))
        editor.add(Link(on: board))
        editor.add(Link(on: nil))
        let entries = editor.contents.entries
        expectEqual(entries.outline, ["Board", "  Link", "Link"])
        expectEqual(entries.first?.children?.first?.symbol, "link")
    },
    test("a row whose shape isn't listed, or is gone, goes at the top") {
        let editor = try contentsEditor()
        let hidden = editor.add(Widget(name: "Hidden", isHidden: true))
        editor.add(Pin("pinned to a hidden widget", on: hidden))
        editor.add(Pin("pinned to nothing", on: ShapeID()))
        expectEqual(editor.contents.entries.outline, ["pinned to a hidden widget", "pinned to nothing"])
    },
    test("a shape the board keeps aside has no row, whatever its kind, and rows naming it go at the top") {
        let registry = try contentsRegistry()
        let gadget = ShapeID(), unread = ShapeID()
        // A kind nobody installs, and a widget whose props don't read.
        let json = """
        { "format" : 1, "schema" : { "widget" : 0 }, "shapes" : [
          { "id" : "\(gadget)", "index" : "a0", "kind" : "gadget", "props" : { "frame" : [[0, 0], [40, 40]] } },
          { "id" : "\(unread)", "index" : "a1", "kind" : "widget", "props" : { "frame" : "not a frame" } } ] }
        """
        let document = try BoardCodec(registry: registry).decode(Data(json.utf8)).document
        expect(try require(document[gadget]).isOpaque)
        expect(try require(document[unread]).isOpaque)
        let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
        editor.add(Widget(name: "Shown"))
        editor.add(Pin("pinned to the gadget", on: gadget))
        editor.add(Link(on: unread))
        expectEqual(editor.contents.entries.outline, ["Shown", "pinned to the gadget", "Link"])
    },
    test("rows nest as deep as their shapes do, and a loop keeps the later shape at the top") {
        let editor = try contentsEditor()
        let a = ShapeID(), b = ShapeID(), c = ShapeID()
        editor.add(Pin("a", on: b), id: a)
        editor.add(Pin("b", on: a), id: b)          // a loop with a
        editor.add(Pin("c", on: a), id: c)
        expectEqual(editor.contents.entries.outline, ["b", "  a", "    c"])
    },
    test("a row is made again only when its own shape changes") {
        let editor = try contentsEditor()
        let widget = editor.add(Widget(name: "Watched"))
        let box = editor.add(Box(widgetFrame))
        _ = editor.contents.entries
        let made = widgetRowsMade
        editor.transact { $0.update(box, as: Box.self) { $0.props.frame.origin.x += 10 } }
        _ = editor.contents.entries
        expectEqual(widgetRowsMade, made, "another shape moved")
        editor.transact { $0.update(widget, as: Widget.self) { $0.props.name = "Renamed" } }
        expectEqual(editor.contents.entries.outline, ["Renamed", "box"])
        expectEqual(widgetRowsMade, made + 1)
    },
    test("a deleted shape leaves the list") {
        let editor = try contentsEditor()
        let widget = editor.add(Widget(name: "Doomed"))
        editor.add(Widget(name: "Kept"))
        _ = editor.contents.entries
        editor.transact { $0.delete([widget]) }
        expectEqual(editor.contents.entries.outline, ["Kept"])
    },
    test("another plugin gives a kind it doesn't register a row, typed as that kind") {
        let bridge = Contributor(id: "box-rows") { $0.contentsRow(Box.self, when: { $0.frame.width > 50 }) { box in ContentsLabel("Box \(Int(box.frame.width)) wide") } }
        let editor = try contentsEditor([bridge])
        editor.add(Box(widgetFrame))
        editor.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        editor.add(Widget(name: "Own"))
        expectEqual(editor.contents.entries.outline, ["Box 100 wide", "Own"])
    },
    test("two rows for one kind conflict, and a row needs the table of contents installed") {
        let twice = Contributor(id: "twice") { $0.contentsRow(Widget.self) { _ in ContentsLabel("again") } }
        expectThrows(RegistryError.conflict(point: "ContentsRows", key: "widget", plugins: ["widgets", "twice"])) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), WidgetsPlugin(), TableOfContentsPlugin(), twice])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ContentsRows", owner: .tableOfContents, contributor: "widgets")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), WidgetsPlugin()])
        }
    },
    test("without the plugin there's no table of contents") {
        let editor = CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()]), scheduler: ManualScheduler())
        expect(editor.tableOfContents == nil)
    },
])
