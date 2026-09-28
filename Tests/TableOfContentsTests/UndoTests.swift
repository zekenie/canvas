@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TableOfContents
import TestKit

@MainActor let undoTests = Suite("The table of contents and undo", [
    test("rows follow undo and redo: renamed, removed, restacked and nested, as listing afresh gives them") {
        let editor = try contentsEditor()
        let a = editor.add(Widget(name: "Alpha"))
        let b = editor.add(Widget(name: "Beta", count: 2))
        editor.add(Gizmo())
        editor.replaceDocument(with: editor.document)
        let pin = ShapeRecord(Pin("Pinned", on: a))
        let steps: [(String, @MainActor () -> Void)] = [
            ("rename", { editor.transact { $0.update(a, as: Widget.self) { $0.props.name = "Apple" } } }),
            ("pin", { editor.transact { $0.insert(pin) } }),
            ("restack", { editor.transact { $0.sendToBack(b) } }),
            ("hide", { editor.transact { $0.update(b, as: Widget.self) { $0.props.isHidden = true } } }),
            ("delete", { editor.transact { $0.delete([a]) } }),
        ]
        var listed = [editor.contents.entries.tree]
        for (name, step) in steps {
            step()
            expectEqual(editor.contents.entries.tree, listedAfresh(editor), name)
            listed.append(editor.contents.entries.tree)
        }
        for expected in listed.dropLast().reversed() {
            editor.undo()
            expectEqual(editor.contents.entries.tree, listedAfresh(editor))
            expectEqual(editor.contents.entries.tree, expected)
        }
        for expected in listed.dropFirst() {
            editor.redo()
            expectEqual(editor.contents.entries.tree, expected)
        }
    },
])
