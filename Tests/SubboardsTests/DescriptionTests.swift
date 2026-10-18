import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Mentions
import Selection
import Subboards
import TestKit
import TextEditing
import Titles

/// The root of two titled subboards: Kitchen (S, at `cardFrame`) and Pantry (P), right of it.
private struct Rooms {
    let s = ShapeID(), p = ShapeID()

    var file: CanvasFile {
        var kitchen = ShapeRecord(id: s, Subboard(frame: cardFrame))
        kitchen[TitleProperty.self] = "Kitchen"
        var pantry = ShapeRecord(id: p, Subboard(frame: CGRect(x: 320, y: 40, width: 240, height: 160)))
        pantry[TitleProperty.self] = "Pantry"
        return CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(kitchen), AnyShapeRecord(pantry)]))
    }

    /// The panel beside the canvas, Kitchen selected, once its description's box shows.
    @MainActor func panel(_ more: [any CanvasPlugin] = []) throws -> (PanelWindow, MentionTextView<AnyMentionable>) {
        let editor = try CanvasEditor(registry: Registry(plugins: subboardPlugins() + more), file: file, scheduler: TaskScheduler())
        editor.selection = s
        let w = PanelWindow(editor)
        w.window.spin { w.descriptionBox != nil }
        return (w, try require(w.descriptionBox))
    }
}

extension PanelWindow {
    /// The box the subboard's description is edited in: the panel's only mention text.
    var descriptionBox: MentionTextView<AnyMentionable>? { hosting.descendants(MentionTextView<AnyMentionable>.self).first }

    /// Gives the box the keyboard, the caret at the end of its text, as a click there does.
    func focus(_ view: NSTextView) {
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: view.textStorage?.length ?? 0, length: 0))
        window.settle()
    }
}

extension CanvasEditor {
    /// A subboard's description, as the board holds it.
    func description(_ id: ShapeID) -> MentionText? { document[id]?.typed(as: Subboard.self)?.props.description }
}

@MainActor let descriptionTests = Suite("The description", [
    test("a subboard's panel opens on its Description tab, a box of mention text for the subboard, empty but for its placeholder") {
        let rooms = Rooms()
        let (w, view) = try rooms.panel()
        let state = try require(w.editor.detailPanel)
        let layout = state.layout(for: try require(w.editor.document[rooms.s]))
        expectEqual(layout.tabs.first?.title, "Description", "the kind's own tab, before the ones every shape has")
        expectEqual(state.currentTab(in: layout, for: Subboard.kind)?.title, "Description")
        expectEqual(view.owner, rooms.s, "its picker may offer the subboard itself")
        expectEqual(view.placeholder, "Add a description")
        expectEqual(view.string, "")
        expect(view.isEditable)
        expectEqual(w.editor.description(rooms.s), "")
    },

    test("typing in it writes the description as it goes, one step named Change Description; @ picks a shape as a pill, which the subboard then mentions") {
        let rooms = Rooms()
        let (w, view) = try rooms.panel()
        w.focus(view)
        w.window.type("Next to @pan")
        expectEqual(view.picker?.rows.compactMap(\.candidate?.id), [rooms.p])
        w.window.pressReturn()
        expect(view.picker == nil)
        let expected = MentionText([.text("Next to "), .mention(rooms.p, label: "Pantry"), .text(" ")])
        expectEqual(w.editor.description(rooms.s), expected)
        expectEqual(w.editor.description(rooms.s)?.stored, "Next to @[Pantry](shape:\(rooms.p.rawValue.uuidString)) ")
        expectEqual(view.pills.count, 1)
        w.window.settle()                                   // the panel draws what was typed

        let mentions = try require(w.editor.mentions)
        expectEqual(mentions.mentions(in: rooms.s), [rooms.p], "a mention edge, slot description")
        expectEqual(mentions.mentioners(of: rooms.p), [rooms.s])
        expectEqual(mentions.quote(of: rooms.s, around: rooms.p), "Next to @Pantry", "what the Connections tab quotes under Kitchen")

        w.editor.undoHistory.seal()
        expectEqual(w.editor.undoHistory.undoName, "Change Description")
        w.editor.undo()
        expectEqual(w.editor.description(rooms.s), "", "one step: the typing and the pick")
        expectEqual(mentions.mentioners(of: rooms.p), [])
        w.window.spin { view.string.isEmpty }
    },

    test("a rename of what it mentions shows in its pill, writing nothing") {
        let rooms = Rooms()
        let (w, view) = try rooms.panel()
        w.editor.transact("Describe") { transaction in
            transaction.update(rooms.s, as: Subboard.self) { $0.props.description = MentionText([.mention(rooms.p, label: "Pantry")]) }
        }
        w.window.spin { view.pills.count == 1 }
        let stored = w.editor.description(rooms.s)
        w.editor.transact("Rename") { transaction in
            transaction.update(rooms.p) { $0[TitleProperty.self] = "Larder" }
        }
        w.window.spin { view.pills.first?.pill.writtenLabel == "Larder" }
        expectEqual(w.editor.description(rooms.s), stored, "the description holds the name it was written with")
    },

    test("a read-only subboard's description reads, but takes no typing and opens no picker") {
        let rooms = Rooms()
        let (w, view) = try rooms.panel([FreezingPlugin()])
        w.editor.transact("Describe") { transaction in
            transaction.update(rooms.s, as: Subboard.self) { $0.props.description = "Where the pans go" }
        }
        w.editor.freeze([rooms.s])
        w.window.spin { !view.isEditable }
        w.focus(view)
        w.window.type("@pan")
        expect(view.picker == nil)
        expectEqual(w.editor.description(rooms.s), "Where the pans go")
        w.editor.freeze([rooms.s], false)
        w.window.spin { view.isEditable }
    },
])

extension MentionTextView {
    /// The pills in the text.
    var pills: [(location: Int, pill: MentionAttachment)] {
        guard let storage = textStorage else { return [] }
        var found: [(Int, MentionAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let pill = value as? MentionAttachment { found.append((range.location, pill)) }
        }
        return found
    }
}
