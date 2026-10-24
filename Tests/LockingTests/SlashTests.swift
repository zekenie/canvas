@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Locking
import SlashCommands
import TestKit

// `/lock` and `/unlock`, the slash commands Locking offers on the kinds that can be locked: `/lock` while
// the shape isn't, one undo step like the menu's Lock, and `/unlock` while it is, reached for the shapes
// selected and never from a shape's text, since a locked shape's text can't be edited. Each reaches
// exactly the shapes it changes, and only where a lock can change: not a shape a locked frame holds.
// Typing `/lock` is the shipped app's (CompositionTests).

@MainActor let lockSlashTests = Suite("Locking and slash commands", [
    test("/lock is offered on every shape that can be locked, while it isn't") {
        let h = try lockingHarness()
        let state = try require(h.editor.slashCommands)
        let box = h.add(Box(chipBox))
        let card = h.add(Card(chipBox))
        expectEqual(state.commands(for: box).map(\.name), ["lock"])
        expectEqual(state.commands(for: card).map(\.name), ["lock"])
        expectEqual(state.commands(for: box).first?.argument, nil, "it takes nothing")
        h.editor.lock([box])
        expectEqual(state.commands(for: box).map(\.name), [], "not once it's locked")
        expectEqual(state.commands(for: card).map(\.name), ["lock"])
        h.editor.unlock([box])
        expectEqual(state.commands(for: box).map(\.name), ["lock"], "and again once it's not")
    },

    test("running it locks the shape in one step named Lock, as the menu's item does; undoing it unlocks") {
        let h = try lockingHarness()
        let state = try require(h.editor.slashCommands)
        let box = h.add(Box(chipBox))
        expect(state.run("lock", on: box, with: SlashArguments([])))
        expect(h.editor.isLocked(box))
        expectEqual(h.editor.undoHistory.undoName, "Lock")
        h.editor.undo()
        expect(!h.editor.isLocked(box))
        expect(!state.run("lock", on: box, with: "now"), "it takes no arguments")
        expect(!h.editor.isLocked(box))
        h.editor.redo()
        expect(h.editor.isLocked(box))
        expect(!state.run("lock", on: box, with: SlashArguments([])), "a locked shape doesn't offer it")
    },

    test("/unlock is reached for a selection of a locked shape and never from its text: one step named Unlock, undone and redone") {
        let h = try lockingHarness()
        let state = try require(h.editor.slashCommands)
        let box = h.add(Box(chipBox))
        expectEqual(state.commands(for: .selection([box])).map(\.name), ["lock"], "unlocked, a selection is offered /lock alone")
        expectEqual(state.commands(for: box).map(\.name), ["lock"], "and so is its text, as ever: never /unlock")
        h.editor.lock([box])
        expectEqual(state.commands(for: box).map(\.name), [], "its text can't be written once it's locked, so nothing could be typed there")
        expect(state.command(named: "unlock", for: box) == nil)
        expect(!state.run("unlock", on: box, with: SlashArguments([])), "never run on a text")
        expect(h.editor.isLocked(box))
        let found = state.commands(for: .selection([box]))
        expectEqual(found.map(\.name), ["unlock"], "its selection is offered the command whose rule can act on it")
        let unlock = try require(found.first)
        expectEqual(unlock.reach, .together)
        expectEqual(unlock.shapes, [box])
        expectEqual(unlock.targetCount, 1)
        expect(!unlock.isPartial)
        expectEqual(unlock.argument, nil, "it takes nothing")
        expectEqual(unlock.stepName, "Unlock", "the step a person would call it, as the menu's item")
        expect(!state.run(unlock, with: "now"), "it takes no arguments")
        expect(h.editor.isLocked(box))
        expect(state.run(unlock, with: SlashArguments([])))
        expect(!h.editor.isLocked(box))
        expectEqual(h.editor.undoHistory.undoName, "Unlock")
        h.editor.undo()
        expect(h.editor.isLocked(box), "undone")
        h.editor.redo()
        expect(!h.editor.isLocked(box), "and redone")
        expectEqual(state.commands(for: .selection([box])).map(\.name), ["lock"], "and unlocked it offers /lock again")
    },

    test("a selection of a locked and an unlocked shape lists /lock and /unlock, each on the one it changes, 1 of 2, in the first shape's order; each leaves the other as it was") {
        let h = try lockingHarness()
        let state = try require(h.editor.slashCommands)
        let free = h.add(Box(chipBox))
        let locked = h.add(Card(chipBox.offsetBy(dx: 300, dy: 0)))
        h.editor.lock([locked])
        let found = state.commands(for: .selection([free, locked]))
        expectEqual(found.map(\.name), ["lock", "unlock"])
        let lock = try require(found.first { $0.name == "lock" })
        let unlock = try require(found.first { $0.name == "unlock" })
        expectEqual(lock.shapes, [free])
        expectEqual(unlock.shapes, [locked])
        for command in found {
            expectEqual(command.targetCount, 2, command.name)
            expect(command.isPartial, command.name)
            expectEqual(command.reach, .together, command.name)
        }
        expectEqual(state.commands(for: .selection([locked, free])).map(\.name), ["unlock", "lock"], "the first shape's, then what only the next offers")

        expect(state.run(lock, with: SlashArguments([])))
        expect(h.editor.isLocked(free) && h.editor.isLocked(locked))
        expectEqual(h.editor.undoHistory.undoName, "Lock")
        h.editor.undo()
        expect(!h.editor.isLocked(free), "one step, undone whole")
        expect(h.editor.isLocked(locked), "the locked one was not reached")

        expect(state.run(unlock, with: SlashArguments([])))
        expect(!h.editor.isLocked(free) && !h.editor.isLocked(locked))
        expectEqual(h.editor.undoHistory.undoName, "Unlock")
        h.editor.undo()
        expect(h.editor.isLocked(locked), "undone")
        expect(!h.editor.isLocked(free), "the unlocked one was not reached")
    },

    test("on shapes alike a command reaches every one, in one step: /lock locks three and, once they are locked, /unlock unlocks all three") {
        let h = try lockingHarness()
        let state = try require(h.editor.slashCommands)
        let shapes = [h.add(Box(chipBox)), h.add(Card(chipBox.offsetBy(dx: 300, dy: 0))), h.add(Box(chipBox.offsetBy(dx: 600, dy: 0)))]
        let target = SlashTarget.selection(shapes)
        let lock = try require(state.command(named: "lock", for: target))
        expectEqual(state.commands(for: target).map(\.name), ["lock"])
        expectEqual(lock.shapes, shapes)
        expect(!lock.isPartial)
        expect(state.run(lock, with: SlashArguments([])))
        expect(shapes.allSatisfy(h.editor.isLocked(_:)))
        expectEqual(h.editor.undoHistory.undoName, "Lock")
        expectEqual(state.commands(for: target).map(\.name), ["unlock"])
        let unlock = try require(state.command(named: "unlock", for: target))
        expectEqual(unlock.shapes, shapes)
        expect(!unlock.isPartial)
        expect(state.run(unlock, with: SlashArguments([])))
        expect(shapes.allSatisfy { !h.editor.isLocked($0) })
        expectEqual(h.editor.undoHistory.undoName, "Unlock")
        h.editor.undo()
        expect(shapes.allSatisfy(h.editor.isLocked(_:)), "all three at once")
    },

    test("a shape a locked frame holds is offered neither /lock nor /unlock, locked on its own or not; the frame is offered /unlock; unlocked, what it held is offered its own again") {
        let h = try lockingHarness([CorralsPlugin()])
        let state = try require(h.editor.slashCommands)
        let corral = h.add(Corral(CGRect(x: 100, y: 100, width: 400, height: 300)))
        let inside = h.add(Box(CGRect(x: 150, y: 150, width: 100, height: 100)))
        let own = h.add(Box(CGRect(x: 300, y: 150, width: 100, height: 100)))
        let outside = h.add(Box(CGRect(x: 600, y: 150, width: 100, height: 100)))
        h.editor.put([inside, own], in: corral)
        h.editor.lock([own])
        h.editor.lock([corral])
        expect(h.editor.isReadOnly(inside) && !h.editor.isLocked(inside), "read-only with the frame, not locked on its own")
        expectEqual(state.commands(for: .selection([inside])).map(\.name), [], "its lock is the frame's to change")
        expectEqual(state.commands(for: .selection([own])).map(\.name), [], "locked on its own as well: neither, while the frame holds it")
        expectEqual(state.commands(for: .selection([inside, own])).map(\.name), [])
        expectEqual(state.commands(for: .selection([corral])).map(\.name), ["unlock"])
        let with = state.commands(for: .selection([inside, corral, outside]))
        expectEqual(with.map(\.name), ["unlock", "lock"], "the frame's, then the free box's: the shape inside is reached by neither")
        expectEqual(with.first { $0.name == "unlock" }?.shapes, [corral])
        expectEqual(with.first { $0.name == "lock" }?.shapes, [outside])
        expect(with.allSatisfy { $0.targetCount == 3 && $0.isPartial })

        expect(state.run("unlock", for: .selection([inside, corral, outside]), with: SlashArguments([])))
        expect(!h.editor.isLocked(corral) && !h.editor.isReadOnly(inside), "the frame unlocked, and what it held with it")
        expect(h.editor.isLocked(own), "a lock of its own is its own")
        expectEqual(h.editor.undoHistory.undoName, "Unlock")
        expectEqual(state.commands(for: .selection([inside])).map(\.name), ["lock"], "free again")
        expectEqual(state.commands(for: .selection([own])).map(\.name), ["unlock"], "and its own lock is offered to be taken off")
    },

    test("a shape locked on a locked subboard's board is offered neither: the board holds its lock; the subboard is offered /unlock") {
        let owner = ShapeID(), inner = ShapeID()
        var locked = AnyShapeRecord(ShapeRecord(id: owner, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))
        locked[LockedProperty.self] = true
        let h = try lockingHarness([PocketsPlugin()], file: CanvasFile(root: CanvasDocument(shapes: [locked]),
                                                                       children: [owner: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: inner, Box(chipBox)))])]))
        let state = try require(h.editor.slashCommands)
        expectEqual(state.commands(for: .selection([owner])).map(\.name), ["unlock"])
        expect(h.enter(owner))
        expect(h.editor.isReadOnly(inner), "the board is read-only")
        expectEqual(state.commands(for: .selection([inner])).map(\.name), [], "neither Lock nor Unlock is for what's on it")
    },
])
