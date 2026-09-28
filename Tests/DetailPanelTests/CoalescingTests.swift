import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Selection
import SwiftUI
import TestKit

// A panel's writes as undo steps: writes to one field, one after another, are one step, until
// anything else happens (the host seals the run on a click or a key elsewhere, which tests do with
// `undoHistory.seal()`).

/// How many steps there are to undo; all of them redone after.
@MainActor func stepCount(_ editor: CanvasEditor) -> Int {
    var n = 0
    while editor.canUndo { editor.undo(); n += 1 }
    while editor.canRedo { editor.redo() }
    return n
}

@MainActor let coalescingTests = Suite("Panel writes and undo", [
    test("typing into a field is one step, until the run is sealed") {
        let editor = try gadgetEditor()
        let id = editor.add(Gadget(gadgetFrame))
        editor.replaceDocument(with: editor.document)
        let gadget = try require(editor.shapeBinding(id, as: Gadget.self))
        for text in ["g", "ga", "gad"] { gadget.name.wrappedValue = text }
        expectEqual(editor.undoHistory.undoName, "Change Gadget", "a binding of no section's is named for the kind")
        editor.undoHistory.seal()
        gadget.name.wrappedValue = "gadg"
        expectEqual(stepCount(editor), 2)
        editor.undo()
        expectEqual(editor.props(id, as: Gadget.self)?.name, "gad")
        editor.undo()
        expectEqual(editor.props(id, as: Gadget.self)?.name, "")
    },
    test("two fields are two steps, and so is the same field again after another; the frame's too") {
        let editor = try gadgetEditor()
        let id = editor.add(Gadget(gadgetFrame))
        editor.replaceDocument(with: editor.document)
        let gadget = try require(editor.shapeBinding(id, as: Gadget.self))
        gadget.name.wrappedValue = "a"
        gadget.name.wrappedValue = "ab"
        gadget.count.wrappedValue = 1
        gadget.count.wrappedValue = 2
        gadget.name.wrappedValue = "abc"
        let frame = try require(editor.frameBinding(id))
        frame.origin.x.wrappedValue = 10
        frame.origin.x.wrappedValue = 11
        frame.size.width.wrappedValue = 300
        expectEqual(stepCount(editor), 5)
    },
    test("update is a step of its own, every time") {
        let editor = try gadgetEditor()
        let id = editor.add(Gadget(gadgetFrame))
        editor.replaceDocument(with: editor.document)
        let gadget = try require(editor.shapeBinding(id, as: Gadget.self))
        gadget.update { $0.count += 1 }
        gadget.update { $0.count += 1 }
        gadget.name.wrappedValue = "x"
        gadget.update { $0.name += "y" }
        expectEqual(stepCount(editor), 4)
    },
    test("update(\\.field), a field written through a method, runs together with the field's binding, and apart from others") {
        let editor = try gadgetEditor()
        let id = editor.add(Gadget(gadgetFrame))
        editor.replaceDocument(with: editor.document)
        let gadget = try require(editor.shapeBinding(id, as: Gadget.self))
        gadget.update(\.name) { $0.name = "g" }
        gadget.update(\.name) { $0.name += "a" }
        gadget.name.wrappedValue = "gad"
        expectEqual(editor.undoHistory.undoName, "Change Gadget")
        gadget.update(\.count) { $0.count = 3 }
        gadget.update(\.count) { $0.count += 1 }
        gadget.update(\.name) { $0.name += "g" }
        expectEqual(stepCount(editor), 3)
        editor.undo()
        expectEqual(editor.props(id, as: Gadget.self)?.name, "gad")
        editor.undo()
        expectEqual(editor.props(id, as: Gadget.self)?.count, 0, "the count's writes, one step")
        editor.undo()
        expectEqual(editor.props(id, as: Gadget.self)?.name, "", "the name's, through update and the binding alike")
    },
    test("an added property's writes run together too, and each shape's apart") {
        let editor = try gadgetEditor([BadgesPlugin()])
        let a = editor.add(Gadget(gadgetFrame)), b = editor.add(Gadget(gadgetFrame))
        editor.replaceDocument(with: editor.document)
        let gadget = try require(editor.shapeBinding(a, as: Gadget.self))
        let seal = gadget[Seal.self]
        seal.wrappedValue = "w"
        seal.wrappedValue = "wa"
        seal.wrappedValue = "wax"
        let badges = try require(editor.propertyBinding(a, Badges.self))
        badges[dynamicMember: \.self].wrappedValue = ["one"]
        badges[dynamicMember: \.self].wrappedValue = ["one", "two"]
        let other = try require(editor.propertyBinding(b, Badges.self))
        other[dynamicMember: \.self].wrappedValue = ["three"]
        expectEqual(stepCount(editor), 3)
        editor.undo(); editor.undo()
        expectEqual(editor.document[a]?[Seal.self], "wax")
        expectEqual(editor.document[a]?[Badges.self], [])
        editor.undo()
        expectEqual(editor.document[a]?[Seal.self], nil)
    },
    test("in a window, a section's writes are named for it: Change and its title, or the kind's name without one") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Gadget(gadgetFrame))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("Name"))
        panel.window.type("gv")
        expectEqual(editor.props(id, as: Gadget.self)?.name, "gv")
        expectEqual(editor.undoHistory.undoName, "Change Gadget")
        panel.window.focus(try panel.field("0 x"))
        panel.window.type("7")
        panel.window.pressReturn()
        panel.window.spin { editor.props(id, as: Gadget.self)?.count == 7 }
        expectEqual(editor.undoHistory.undoName, "Change Count")
        editor.undo()
        expectEqual(editor.props(id, as: Gadget.self)?.count, 0)
        expectEqual(editor.undoHistory.undoName, "Change Gadget")
        editor.undo()
        expectEqual(editor.props(id, as: Gadget.self)?.name, "")
    },
])
