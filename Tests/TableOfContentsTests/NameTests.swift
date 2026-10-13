import Canvas
import CanvasTesting
import CoreGraphics
import SwiftUI
import TableOfContents
import TestKit

// Names from a plugin other than the one that draws the row (`ContentsTitles`), as Titles gives them.
@MainActor let nameTests = Suite("Table of contents: names", [
    test("a name takes the place of a row's title; the row keeps its symbol and badge") {
        let editor = try contentsEditor([Contributor(id: "names") { r in r.contentsTitle(Widget.self) { $0.props.count > 0 ? "Counted" : nil } }])
        editor.add(Widget(name: "First", count: 3))
        let second = editor.add(Widget(name: "Second"))
        let entries = editor.contents.entries
        expectEqual(entries.outline, ["Counted", "Second"])
        expectEqual(entries.map { $0.label?.badge }, ["3", nil])
        expectEqual(entries.map(\.symbol), ["gearshape", "gearshape"])

        editor.transact { $0.update(second, as: Widget.self) { $0.props.count = 1 } }
        expectEqual(editor.contents.entries.outline, ["Counted", "Counted"], "made again as its shape changes")
    },
    test("a blank name keeps the row's title, placeholder and all") {
        let editor = try contentsEditor([Contributor(id: "names") { r in r.contentsTitle(Widget.self) { _ in " \n" } }])
        editor.add(Widget(name: ""))
        expectEqual(editor.contents.entries.outline, ["Unnamed"])
        expectEqual(editor.contents.entries.first?.label?.isPlaceholder, true)
    },
    test("a kind with no row is listed by its name, with its tool's symbol") {
        let editor = try contentsEditor([Contributor(id: "names") { r in r.contentsTitle(Gizmo.self) { "Gizmo \(Int($0.frame.width))" } }])
        editor.add(Gizmo())
        expectEqual(editor.contents.entries.outline, ["Gizmo 100"])
        expectEqual(editor.contents.entries.map(\.symbol), ["cube"])
    },
    test("a kind with no row that another plugin names shows its tool's label dimmed until a shape is named; one nobody names, at full strength") {
        let editor = try contentsEditor([Contributor(id: "names") { r in r.contentsTitle(Gizmo.self) { $0.frame.width > 100 ? "Wide" : nil } }])
        let gizmo = editor.add(Gizmo(CGRect(x: 0, y: 0, width: 100, height: 50)))
        var label = try require(editor.contents.entries.first?.label)
        expectEqual(label.text, "Gizmo")
        expect(label.isPlaceholder, "unnamed: dimmed, as an untitled note is")
        editor.transact { $0.update(gizmo, as: Gizmo.self) { $0.frame.size.width = 200 } }
        label = try require(editor.contents.entries.first?.label)
        expectEqual(label.text, "Wide")
        expect(!label.isPlaceholder, "named")
        let unnamed = try contentsEditor()
        unnamed.add(Gizmo())
        label = try require(unnamed.contents.entries.first?.label)
        expectEqual(label.text, "Gizmo")
        expect(!label.isPlaceholder, "a kind nobody names: its label is all it's called")
    },
    test("a row that isn't a ContentsLabel stays its kind's view") {
        let editor = try contentsEditor([Contributor(id: "rows") { r in
            r.contentsRow(Box.self) { _ in Text("A box") }
            r.contentsTitle(Box.self) { _ in "Named" }
        }])
        editor.add(Box(widgetFrame))
        expectEqual(editor.contents.entries.outline, ["<view>"])
    },
    test("what the list calls a shape is said for any shape of the file: its row's text, named or not, with no row made or kept") {
        let titled = Contributor(id: "names") { r in r.contentsTitle(Widget.self) { $0.props.count > 0 ? "Counted" : nil } }
        let views = Contributor(id: "rows") { r in r.contentsRow(Box.self) { _ in Text("A box") } }
        let editor = try contentsEditor([titled, views])
        let named = ShapeRecord(Widget(name: "First")), counted = ShapeRecord(Widget(name: "Second", count: 2))
        let unnamed = ShapeRecord(Widget(name: " ")), gizmo = ShapeRecord(Gizmo()), box = ShapeRecord(Box(widgetFrame))
        #if DEBUG
        let made = editor.contents.rowsMade
        #endif
        // None of them is in the file: a name is its record's, wherever that is.
        expectEqual(editor.contents.name(of: AnyShapeRecord(named)), "First", "its row's title")
        expectEqual(editor.contents.name(of: AnyShapeRecord(counted)), "Counted", "as another plugin names it")
        expectEqual(editor.contents.name(of: AnyShapeRecord(unnamed)), "Unnamed", "its row's placeholder")
        expectEqual(editor.contents.name(of: AnyShapeRecord(gizmo)), "Gizmo", "a kind with no row: its kind's name")
        expectEqual(editor.contents.name(of: AnyShapeRecord(box)), nil, "a row that is no label says no name")
        #if DEBUG
        expectEqual(editor.contents.rowsMade, made, "no row is made for it")
        #endif
        expectEqual(editor.contents.entries.count, 0, "and nothing is listed")
    },
    test("a kind's rows have one name: two plugins naming them conflict") {
        expectThrows(RegistryError.conflict(point: "ContentsTitles", key: "widget", plugins: ["a", "b"])) {
            _ = try contentsEditor([Contributor(id: "a") { $0.contentsTitle(Widget.self) { _ in "A" } },
                                    Contributor(id: "b") { $0.contentsTitle(Widget.self) { _ in "B" } }])
        }
    },
])
