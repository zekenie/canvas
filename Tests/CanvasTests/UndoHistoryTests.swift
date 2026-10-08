@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// The core's undo history, with no Keyboard or Selection: presses go through the Hand (the default
// tool) or a test's own tools, keys through a test's own key-stroke handler.

/// Every event a board's history sends its host.
@MainActor final class UndoEvents {
    var events: [UndoEvent] = []
    init(_ editor: CanvasEditor) {
        editor.undoHistory.didChange = { [unowned self] in events.append($0) }
    }
}

/// A tool whose press moves the shape under it with the pointer: a `TranslatingSession`, as the
/// select tool's drag would be.
@MainActor final class MoverTool {}

extension MoverTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        guard let id = editor.shape(at: pointer.world) else { return }
        editor.session = TranslatingSession(ids: [id], from: pointer.world, in: editor)
    }
}

/// Keeps what each undo snapshot was: a number, bumped by the test.
@MainActor final class Counter {
    var value = 0
    var restored: [Int] = []
}

extension Counter: UndoParticipant {
    func undoSnapshot(in editor: CanvasEditor) -> any Sendable { value }
    func restoreUndoSnapshot(_ snapshot: any Sendable, in editor: CanvasEditor) {
        value = snapshot as? Int ?? -1
        restored.append(value)
    }
}

/// Stands in for a hosting view: when editing ends, the editing view saves ("!" on the card's
/// text), as a text field does when it closes.
@MainActor final class SavingHost {
    private var field: CardField?
    init(_ editor: CanvasEditor) { editor.delegate = self }
}

extension SavingHost: CanvasEditorDelegate {
    func editorNeedsDisplay(_ editor: CanvasEditor) {}
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {
        if let field {
            field.context.update { $0.text += "!" }
            self.field = nil
        }
        field = editor.makeEditingView()?.view as? CardField
    }
}

@MainActor private func typing(_ editor: CanvasEditor, _ text: String) throws {
    let field = try require(editor.makeEditingView()?.view as? CardField, "editing")
    for character in text { field.context.update { $0.text.append(character) } }
}

/// Boxes, discs (with a place tool that drags what it places), editable cards, and the mover.
@MainActor private func boxes(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let plugins: [any CanvasPlugin] = [
        Contributor(id: "boxes") { r in
            r.shape(BoxDefinitionForTests())
            r.tool(ToolDescriptor(id: "mover", label: "Mover", systemImage: "arrow")) { _ in MoverTool() }
        },
        discTools(), CardsPlugin(),
    ]
    let registry = try Registry(plugins: plugins + more)
    return EditorHarness { CanvasEditor(registry: registry, scheduler: $0, stackingKeys: .sequential) }
}

/// What's there so far, as the start: nothing to undo.
@MainActor private func forget(_ h: EditorHarness) { h.editor.replaceDocument(with: h.editor.document) }

private let frame = CGRect(x: 0, y: 0, width: 100, height: 100)

@MainActor let undoHistoryTests = Suite("Undo history", [
    test("each commit on its own is a step, named by its transaction; undo and redo put back exactly what was, as commits") {
        let log = ChangeLog()
        let h = try boxes([recordingChanges(log)])
        let a = h.add(Box(frame)), b = h.add(Box(frame.offsetBy(dx: 200, dy: 0)))
        forget(h)
        let start = h.editor.document
        h.editor.transact("Nudge") { $0.update(a, as: Box.self) { $0.frame.origin.x = 10 } }
        let nudged = h.editor.document
        h.editor.transact("Delete") { $0.delete([b]) }
        expectEqual(h.editor.undoHistory.undoName, "Delete")
        expect(h.editor.canUndo && !h.editor.canRedo)
        let revision = h.editor.revision
        log.changes = []
        h.editor.undo()
        expectEqual(h.editor.document, nudged)
        expectEqual(h.editor.revision, revision + 1)
        expectEqual(log.changes.map(\.shapeIDs), [[b]], "services hear the shapes the step touched, and no other")
        expectEqual(log.changes.first?.added, [b])
        expectEqual(log.changes.map(\.restoredStep), [true], "a step put back, which a sync follows as no edit")
        expectEqual(log.changes.map(\.replacedDocument), [false])
        expectEqual(h.editor.undoHistory.undoName, "Nudge")
        expectEqual(h.editor.undoHistory.redoName, "Delete")
        h.editor.undo()
        expectEqual(h.editor.document, start)
        expect(!h.editor.canUndo && h.editor.canRedo)
        h.editor.undo()                                             // nothing left: nothing happens
        expectEqual(h.editor.document, start)
        h.editor.redo(); h.editor.redo()
        expectEqual(h.editor.document[a]?.box?.origin.x, 10)
        expectEqual(h.editor.document[b], nil)
        expectEqual(log.changes.last?.removed, [b])
        expectEqual(log.changes.last?.restoredStep, true, "redone too")
        expect(!h.editor.canRedo)
        expectEqual(h.editor.undoHistory.undoName, "Delete")
    },
    test("a press that places a shape and drags it is one step, named for the place tool; a hand drag is none") {
        let h = try boxes()
        let events = UndoEvents(h.editor)
        h.editor.setTool(ToolID(placing: Disc.kind))
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 150, y: 120)); h.drag(to: CGPoint(x: 200, y: 140))
        expect(!h.editor.canUndo, "not while the press's session runs")
        h.release()
        expectEqual(h.editor.undoHistory.undoName, "Add Disc")
        expectEqual(events.events, [.began, .closed])
        h.press(at: CGPoint(x: 500, y: 500)); h.drag(to: CGPoint(x: 600, y: 600)); h.release()
        expectEqual(events.events, [.began, .closed], "panning isn't a step")
        h.editor.undo()
        expectEqual(h.editor.document.shapes, [])
        h.editor.redo()
        expectEqual(h.editor.document.shapes.first?.box?.origin, CGPoint(x: 180, y: 120))
    },
    test("a drag put back with Escape comes to nothing, and is dropped") {
        let h = try boxes()
        let box = h.add(Box(frame))
        let events = UndoEvents(h.editor)
        let undoName = h.editor.undoHistory.undoName
        h.editor.setTool("mover")
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 90, y: 90))
        h.escape()
        h.drag(to: CGPoint(x: 120, y: 120))
        h.release()
        expectEqual(h.editor.document[box]?.box, frame)
        expectEqual(events.events, [.began, .discarded])
        expectEqual(h.editor.undoHistory.undoName, undoName, "the step before it is still the one to undo")
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 60, y: 50)); h.release()
        expectEqual(h.editor.undoHistory.undoName, "Move")
    },
    test("placing an editable card and typing into it is one step, the editing view's closing save included") {
        let h = try boxes()
        let host = SavingHost(h.editor)
        h.editor.setTool(ToolID(placing: Card.kind))
        h.press(at: CGPoint(x: 100, y: 100)); h.release()
        let card = try require(h.editor.editingShapeID)
        try typing(h.editor, "hi")
        h.editor.endEditing()
        _ = host
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "hi!")
        expectEqual(h.editor.undoHistory.undoName, "Add Card")
        h.editor.undo()
        expectEqual(h.editor.document.shapes, [], "one undo takes the card and its text away")
        h.editor.redo()
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "hi!")
    },
    test("editing a card is one step, Typing, until editing ends; a change from elsewhere ends it, and typing after that is another") {
        let h = try boxes()
        let card = h.add(Card(frame))
        let other = h.add(Box(frame.offsetBy(dx: 200, dy: 0)))
        h.editor.beginEditing(card)
        try typing(h.editor, "abc")
        expectEqual(h.editor.undoHistory.undoName, "Typing")
        h.editor.transact { $0.update(other, as: Box.self) { $0.frame.origin.y = 5 } }
        try typing(h.editor, "de")
        h.editor.endEditing()
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "abcde")
        h.editor.undo()
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "abc")
        h.editor.undo()
        expectEqual(h.editor.document[other]?.box?.origin.y, 0)
        h.editor.undo()
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "")
    },
    test("undo while a card is being edited ends editing and undoes what was typed") {
        let h = try boxes()
        let card = h.add(Card(frame))
        h.editor.beginEditing(card)
        try typing(h.editor, "abc")
        expect(h.editor.canUndo)
        h.editor.undo()
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "")
        h.editor.redo()
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "abc")
    },
    test("Undo run as a command or from a key while a card is being edited ends editing and undoes the session, its closing save included") {
        let h = try boxes([Contributor(id: "keys") { r in
            r.keyStrokes { editor, stroke in stroke.characters == "z" && editor.perform(.undo) }
        }])
        let host = SavingHost(h.editor)
        let card = h.add(Card(frame))
        forget(h)
        h.editor.beginEditing(card)
        try typing(h.editor, "abc")
        expect(h.editor.perform(.undo))
        _ = host
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "", "the typing and the save it closed with, in one undo")
        expect(!h.editor.canUndo)
        expectEqual(h.editor.undoHistory.redoName, "Typing")
        expect(h.editor.perform(.redo))
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "abc!")
        h.editor.beginEditing(card)
        try typing(h.editor, "d")
        expect(h.key("z"))
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "abc!", "a key's Undo too")
        expectEqual(h.editor.undoHistory.undoName, "Typing")
        expectEqual(h.editor.undoHistory.redoName, "Typing")
    },
    test("an open step whose changes have come back to where they began neither names Undo nor enables it") {
        let h = try boxes()
        let box = h.add(Box(frame))
        forget(h)
        @MainActor func x(_ value: CGFloat) {
            h.editor.transact("Change X", coalescing: "x") { $0.update(box, as: Box.self) { $0.frame.origin.x = value } }
        }
        x(7); x(0)
        expect(!h.editor.canUndo && !h.editor.canPerform(.undo), "nothing to undo: the run came to nothing")
        expectEqual(h.editor.undoHistory.undoName, nil)
        expect(!h.editor.perform(.undo))
        h.editor.transact("Nudge") { $0.update(box, as: Box.self) { $0.frame.origin.y = 5 } }
        x(7)
        expectEqual(h.editor.undoHistory.undoName, "Change X")
        x(0)
        expectEqual(h.editor.undoHistory.undoName, "Nudge", "Undo says what it will undo")
        expect(h.editor.perform(.undo))
        expectEqual(h.editor.document[box]?.box, frame)
        expectEqual(h.editor.undoHistory.redoName, "Nudge")
    },
    test("a press whose release never came ends as the next press begins: each is a step, and what follows is one of its own") {
        let h = try boxes()
        let box = h.add(Box(frame))
        forget(h)
        let events = UndoEvents(h.editor)
        h.editor.setTool("mover")
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 60, y: 50))
        h.press(at: CGPoint(x: 60, y: 50)); h.drag(to: CGPoint(x: 60, y: 70)); h.release()
        expectEqual(events.events, [.began, .closed, .began, .closed])
        h.editor.transact("Nudge") { $0.update(box, as: Box.self) { $0.frame.size.width = 50 } }
        expectEqual(events.events, [.began, .closed, .began, .closed, .began, .closed], "a commit after it is a step of its own")
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box, CGRect(x: 10, y: 20, width: 100, height: 100))
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box, CGRect(x: 10, y: 0, width: 100, height: 100))
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box, frame)
        expect(!h.editor.canUndo)
    },
    test("a command, a key stroke and a group are each one step; groups nest, and one that commits nothing is none") {
        let h = try boxes([Contributor(id: "actions") { r in
            r.command("spread") { editor in
                editor.transact("Spread") { $0.translate(Set(editor.document.shapes.map(\.id)), by: CGPoint(x: 1, y: 0)) }
                editor.transact { $0.translate(Set(editor.document.shapes.map(\.id)), by: CGPoint(x: 1, y: 0)) }
            }
            r.keyStrokes { editor, stroke in
                guard stroke.characters == "x" else { return false }
                editor.transact { $0.translate(Set(editor.document.shapes.map(\.id)), by: CGPoint(x: 0, y: 1)) }
                editor.transact("Slide") { $0.translate(Set(editor.document.shapes.map(\.id)), by: CGPoint(x: 0, y: 1)) }
                return true
            }
        }])
        let box = h.add(Box(frame))
        let events = UndoEvents(h.editor)
        expect(h.editor.perform("spread"))
        expect(h.key("x"))
        h.editor.undoHistory.group("Outer") {
            h.editor.transact("Inner") { $0.update(box, as: Box.self) { $0.frame.size.width = 50 } }
            h.editor.undoHistory.group("Nested") {
                h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size.height = 50 } }
            }
        }
        h.editor.undoHistory.group("Empty") {}
        expectEqual(events.events, [.began, .closed, .began, .closed, .began, .closed])
        expectEqual(h.editor.undoHistory.undoName, "Outer", "the outermost group names it")
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box, CGRect(x: 2, y: 2, width: 100, height: 100))
        expectEqual(h.editor.undoHistory.undoName, "Slide", "else its first named transaction")
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box, CGRect(x: 2, y: 0, width: 100, height: 100))
        expectEqual(h.editor.undoHistory.undoName, "Spread")
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box, frame)
    },
    test("a held key's repeats are part of the step its first press opened, until another key, a commit, seal or undo") {
        let h = try boxes([Contributor(id: "keys") { r in
            r.keyStrokes { editor, stroke in
                guard stroke.characters == "x" || stroke.characters == "y" else { return false }
                editor.transact("Slide") { $0.translate(Set(editor.document.shapes.map(\.id)), by: CGPoint(x: 1, y: 0)) }
                return true
            }
        }])
        let box = h.add(Box(frame))
        forget(h)
        let events = UndoEvents(h.editor)
        h.key("x")
        h.key("x", isRepeat: true)
        h.key("x", isRepeat: true)
        expectEqual(events.events, [.began], "one step, still taking the key's repeats")
        expectEqual(h.editor.undoHistory.undoName, "Slide")
        h.key("y", isRepeat: true)
        expectEqual(events.events, [.began, .closed, .began], "another key's repeat is a step of its own")
        h.hold(.shift)
        h.key("y", isRepeat: true)
        expectEqual(events.events, [.began, .closed, .began, .closed, .began], "so is the key with other keys held")
        h.hold([])
        h.key("x")
        h.key("x")
        expectEqual(events.events.count, 9, "a press of the key again, not a repeat, is one too")
        h.editor.transact("Nudge") { $0.update(box, as: Box.self) { $0.frame.size.width = 50 } }
        expectEqual(Array(events.events.suffix(3)), [.closed, .began, .closed], "a commit closes it")
        for _ in 0..<5 { h.editor.undo() }
        expectEqual(h.editor.document[box]?.box, frame.offsetBy(dx: 3, dy: 0), "the first key and its two repeats: one step left")
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box, frame)
        h.editor.redo()
        h.key("x", isRepeat: true)
        expectEqual(h.editor.document[box]?.box, frame.offsetBy(dx: 4, dy: 0))
        expectEqual(h.editor.undoHistory.undoName, "Slide")
        h.editor.undoHistory.seal()
        h.key("x", isRepeat: true)
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box, frame.offsetBy(dx: 4, dy: 0), "sealed: the repeat after it is a step of its own")
    },
    test("a held key's step closes as the key is let go (⇧ or not), as every key is (the canvas lost the keyboard), and at a press; an autosave waits for it") {
        let h = try boxes([Contributor(id: "keys") { r in
            r.keyStrokes { editor, stroke in
                guard stroke.characters.lowercased() == "x" else { return false }
                editor.transact("Slide") { $0.translate(Set(editor.document.shapes.map(\.id)), by: CGPoint(x: 1, y: 0)) }
                return true
            }
        }])
        let box = h.add(Box(frame))
        forget(h)
        let events = UndoEvents(h.editor)
        h.key("x")
        h.key("x", isRepeat: true)
        expect(h.editor.undoHistory.isKeyHolding, "held, with changes: an autosave that can wait, waits")
        expect(!h.editor.undoHistory.isPressing)
        h.editor.keyUp(KeyStroke("y"))
        expectEqual(events.events, [.began], "another key's release isn't its")
        h.hold(.shift)
        h.editor.keyUp(KeyStroke("X", modifiers: .shift))
        h.hold([])
        expectEqual(events.events, [.began, .closed], "let go of, with ⇧ held now or not")
        expect(!h.editor.undoHistory.isKeyHolding)
        h.key("x", isRepeat: true)
        expectEqual(events.events, [.began, .closed, .began], "a repeat after it is a step of its own")
        h.editor.keysReleased()
        expectEqual(events.events, [.began, .closed, .began, .closed], "every key let go")
        h.key("x")
        h.press(at: CGPoint(x: 500, y: 500))
        h.release()
        h.key("x", isRepeat: true)
        expectEqual(Array(events.events.suffix(3)), [.began, .closed, .began], "a press (the Hand's, which commits nothing) closes it")
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box, frame.offsetBy(dx: 4, dy: 0), "the repeat after the press, alone")
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box, frame.offsetBy(dx: 3, dy: 0), "the key before it, alone")
        let lone = try boxes([Contributor(id: "keys") { r in r.keyStrokes { _, _ in true } }])
        lone.key("x")
        expect(!lone.editor.undoHistory.isKeyHolding, "a key that commits nothing holds nothing")
    },
    test("commits under one coalescing key are one step, until another key, a commit without one, seal, an action or undo") {
        let h = try boxes()
        let box = h.add(Box(frame))
        @MainActor func width(_ w: CGFloat, key: AnyHashable? = "width") {
            h.editor.transact("Width", coalescing: key) { $0.update(box, as: Box.self) { $0.frame.size.width = w } }
        }
        @MainActor func steps() -> Int {
            var n = 0
            while h.editor.canUndo { h.editor.undo(); n += 1 }
            while h.editor.canRedo { h.editor.redo() }
            return n
        }
        let base = steps()
        width(10); width(20); width(30)
        expectEqual(steps() - base, 1)
        width(40); width(50, key: "height"); width(60, key: "height")
        expectEqual(steps() - base, 3)
        width(70); width(80, key: nil); width(90)
        expectEqual(steps() - base, 6)
        width(91); h.editor.undoHistory.seal(); width(92)
        expectEqual(steps() - base, 8)
        width(93); h.editor.undoHistory.group { _ = 0 }; width(94)
        expectEqual(steps() - base, 10)
        width(95); h.editor.undo(); width(96); width(97)
        expectEqual(h.editor.document[box]?.box?.width, 97)
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box?.width, 94)
        // A run back where it began is no step.
        let events = UndoEvents(h.editor)
        width(10); width(94)
        h.editor.undoHistory.seal()
        expectEqual(events.events, [.began, .discarded])
    },
    test("undo and redo wait for a press's session; a new step clears redo; a new document clears it all; a save point splits a step") {
        let h = try boxes()
        let box = h.add(Box(frame))
        let events = UndoEvents(h.editor)
        h.editor.setTool("mover")
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 60, y: 50))
        expect(!h.editor.canUndo && !h.editor.canPerform(.undo))
        expect(h.editor.undoHistory.isPressing)
        h.editor.undoHistory.breakStep()
        expect(!h.editor.undoHistory.isPressing)
        h.drag(to: CGPoint(x: 70, y: 50)); h.release()
        expectEqual(events.events, [.began, .closed, .began, .closed])
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box?.origin.x, 10, "the rest of the press was its own step")
        expect(h.editor.canRedo)
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.origin.y = 3 } }
        expect(!h.editor.canRedo, "a new step clears redo")
        h.editor.replaceDocument(with: CanvasDocument())
        expect(!h.editor.canUndo && !h.editor.canRedo)
        expectEqual(events.events.last, .cleared)
    },
    test("undo and redo go below read-only rules: unfreezing, and what a deletion did to read-only shapes, come back exactly, with nothing refused") {
        let log = RefusalLog()
        let dependents = Contributor(id: "dependents") { r in
            r.willDelete { ids, tx in
                let discs = tx.document.shapes.filter { $0.kind == Disc.kind }.map(\.id)
                if ids.contains(where: { tx.document[$0]?.kind == Box.kind }) { tx.delete(Set(discs)) }
            }
        }
        let h = try EditorHarness(plugins: [FixturesPlugin(), FreezingPlugin(log: log), dependents])
        let box = h.add(Box(frame))
        let tag = h.add(Tag(target: box))
        let disc = h.add(Disc(frame.offsetBy(dx: 300, dy: 0)))
        h.editor.freeze([tag, disc])
        let frozen = h.editor.document
        h.editor.undo()
        expect(!h.editor.isReadOnly(tag) && !h.editor.isReadOnly(disc), "undoing a freeze thaws")
        h.editor.redo()
        expectEqual(h.editor.document, frozen)
        h.editor.transact("Delete") { $0.delete([box]) }
        expectEqual(h.editor.document[disc], nil, "a read-only dependent goes with its shape")
        expectEqual(h.editor.document[tag]?.typed(as: Tag.self)?.props.target, nil, "a read-only tag lets go")
        let deleted = h.editor.document
        h.editor.undo()
        expectEqual(h.editor.document, frozen, "both come back, read-only and as they were")
        h.editor.redo()
        expectEqual(h.editor.document, deleted)
        expectEqual(log.refusals, [])
        // A transaction all of whose changes are refused commits nothing, so it's no step.
        let undoName = h.editor.undoHistory.undoName
        h.editor.transact("Nudge") { $0.update(tag) { $0.meta = ShapeMeta(json: ["x": 1]) } }
        expectEqual(log.refusals, [[tag]])
        expectEqual(h.editor.undoHistory.undoName, undoName)
    },
    test("participants get back what they kept: from before a step on undo, from after it on redo") {
        let counter = Counter()
        let h = try boxes([Contributor(id: "counter") { r in r.service { _ in counter } }])
        let box = h.add(Box(frame))
        counter.value = 1
        h.editor.undoHistory.group {
            h.editor.transact { $0.update(box, as: Box.self) { $0.frame.origin.x = 5 } }
            counter.value = 2
        }
        counter.value = 3
        h.editor.undo()
        expectEqual(counter.value, 1)
        h.editor.redo()
        expectEqual(counter.value, 2)
        expectEqual(counter.restored, [1, 2])
    },
    test("undo and redo are the core's commands, which run while there's something to undo or redo") {
        let h = try boxes()
        expect(h.editor.registry.claims(.undo) && h.editor.registry.claims(.redo))
        expect(!h.editor.registry.claims("nothing"))
        expect(!h.editor.canPerform(.undo) && !h.editor.canPerform(.redo))
        let box = h.add(Box(frame))
        expect(h.editor.canPerform(.undo))
        expect(h.editor.perform(.undo))
        expectEqual(h.editor.document[box], nil)
        expect(h.editor.canPerform(.redo) && !h.editor.canPerform(.undo))
        expect(h.editor.perform(.redo))
        expect(h.editor.document[box] != nil)
    },
    // Transacting from a service's `documentDidChange` while undo applies a step is a precondition
    // failure (`isApplying`), which a test can't run without stopping.
])
