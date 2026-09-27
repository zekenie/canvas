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
    test("a row that isn't a ContentsLabel stays its kind's view") {
        let editor = try contentsEditor([Contributor(id: "rows") { r in
            r.contentsRow(Box.self) { _ in Text("A box") }
            r.contentsTitle(Box.self) { _ in "Named" }
        }])
        editor.add(Box(widgetFrame))
        expectEqual(editor.contents.entries.outline, ["<view>"])
    },
    test("a kind's rows have one name: two plugins naming them conflict") {
        expectThrows(RegistryError.conflict(point: "ContentsTitles", key: "widget", plugins: ["a", "b"])) {
            _ = try contentsEditor([Contributor(id: "a") { $0.contentsTitle(Widget.self) { _ in "A" } },
                                    Contributor(id: "b") { $0.contentsTitle(Widget.self) { _ in "B" } }])
        }
    },
])
