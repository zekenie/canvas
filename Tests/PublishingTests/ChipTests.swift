import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Geometry
import Neighbors
import Publishing
import Selection
import TestKit

// The chip, as the adornment frames report it (the label as drawn, and where). A fixture chip stands
// in for the lock, last as the lock is and before Publishing in the list as Locking is (two that
// don't know each other go in plugin order), at the right end of the row, so the chip's place beside
// it is held without Locking; and a fixture pill for the title, at the left end, saying a plaque's
// name as Titles' pill says a title (its text alone), so the room the chip leaves it is held without
// Titles.

enum StubLock {}
extension StubLock: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
    static var order: Order<Self> { .last }
}

let stubLock = Contributor(id: "stub-lock") { r in
    r.forEveryShape { scope in
        scope.adornment(StubLock.self) { _, _ in AdornmentLabel(systemImage: "lock.fill") }
    }
}

enum StubTitle {}
extension StubTitle: Adornment {
    static var placement: AdornmentPlacement { .aboveTopLeft }
}

let stubTitle = Contributor(id: "stub-title") { r in
    r.forEveryShape { scope in
        scope.adornment(StubTitle.self) { record, _ in record.typed(as: Plaque.self)?.props.name.map { AdornmentLabel($0) } }
    }
}

extension EditorHarness {
    /// Names a plaque, as titling it would: its stand-in pill says the name, nil none.
    func name(_ plaque: ShapeID, _ name: String?) {
        editor.transact { $0.update(plaque, as: Plaque.self) { $0.props.name = name } }
    }
}

extension EditorHarness {
    /// The private chip as it's laid out now on a shape, if it shows.
    func chip(of id: ShapeID) -> AdornmentFrame? {
        editor.adornmentFrames(of: id).first { $0.adornment == .of(PrivateChip.self) }
    }

    /// The middle of the chip, in view points: where a click on it lands.
    func chipPoint(of id: ShapeID) throws -> CGPoint {
        let rect = try require(chip(of: id), "a chip on the shape").rect
        return view(CGPoint(x: rect.midX, y: rect.midY))
    }

    /// The symbol the chip shows: the crossed eye on a private shape, the open one fading on one just made public; nil
    /// without a chip.
    func chipSymbol(of id: ShapeID) -> String? { chip(of: id)?.label.systemImage }
}

/// Out of the way of any chip, for the pointer.
let elsewhere = CGPoint(x: 600, y: 20)

@MainActor let chipTests = Suite("The private chip", [
    test("a private shape has a chip, the crossed eye alone, 4 points left of the lock's; a public one, as every shape starts, has none") {
        let h = try publishingHarness([stubTitle], before: [stubLock])
        let plaque = h.add(Plaque(plaqueFrame))
        expectEqual(h.chip(of: plaque), nil, "public: none")
        h.conceal(plaque)
        let chip = try require(h.chip(of: plaque))
        expectEqual(chip.label.text, nil, "a symbol alone, as the lock is")
        expectEqual(chip.label.systemImage, "eye.slash")
        expectEqual(chip.label.compactFace, nil, "the eye is its own smallest face")
        let lock = try require(h.editor.adornmentFrames(of: plaque).first { $0.adornment == .of(StubLock.self) })
        expectEqual(chip.rect.maxX, lock.rect.minX - 4, "beside the lock, which is nearest the end")
        expectEqual(lock.rect.maxX, plaqueFrame.maxX)
        expectEqual(chip.rect.minY, lock.rect.minY, "in its row")
        expectEqual(chip.rect.size, lock.rect.size, "the same size as the lock: a symbol alone each")
    },
    test("made public, the eye opens for a moment and fades, a symbol alone as the open lock is") {
        let h = try publishingHarness([stubTitle], before: [stubLock])
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        h.click(at: try h.chipPoint(of: plaque))
        h.move(to: elsewhere)
        let open = try require(h.chip(of: plaque))
        expectEqual(open.label.systemImage, "eye")
        expectEqual(open.label.text, nil)
        expectEqual(open.label.opacity, 1, "lingering")
        h.wait(1380 + 100 + 150)
        let fading = try require(h.chip(of: plaque)).label.opacity
        expect(fading < 1, "fading: \(fading)")
    },
    test("a seal (always public), a draft (never) and a stand-in have no chip: nothing to toggle, and nothing makes them private") {
        let h = try publishingHarness([stubTitle], before: [stubLock])
        let seal = h.add(Seal(plaqueFrame)), draft = h.add(Draft(plaqueFrame)), holder = h.hold([seal])
        h.conceal(seal, draft, holder)
        for id in [seal, draft, holder] {
            expectEqual(h.chip(of: id), nil)
            expectEqual(h.editor.document[id]?[PrivateProperty.self], nil, "nothing written")
            expect(h.editor.adornmentFrames(of: id).contains { $0.adornment == .of(StubLock.self) }, "the others' chips are still there")
        }
    },
    test("below 35%, where shapes are skeletons, no chip is laid out, so a click where it would be changes nothing; at 35% it's there") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(CGRect(x: 100 / 0.3, y: 100 / 0.3, width: 150 / 0.3, height: 100 / 0.3)))
        h.conceal(plaque)
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expectEqual(h.editor.adornmentFrames(of: plaque), [], "none laid out")
        expectEqual(h.chip(of: plaque), nil)
        h.editor.skeletonZoom = 0.2
        expect(h.chip(of: plaque) != nil, "in full at 30%")
    },
    test("a public shape wears nothing however many things stand for it, direct or dynamic: they are what holds it public, listed in Connections") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        let publishing = try require(h.editor.publishing)
        let first = h.hold([plaque])
        let second = h.add(Relay(plaqueFrame, stands: [Citation(plaque)]))
        let lens = h.lens("what", answering: [plaque])
        expectEqual(publishing.standIns(for: plaque).count, 3, "a direct stand-in of each kind and a dynamic one")
        expectEqual(h.chip(of: plaque), nil)
        h.editor.transact { $0.delete([first]) }
        expectEqual(publishing.standIns(for: plaque).count, 2)
        h.editor.undo()
        expectEqual(publishing.standIns(for: plaque).count, 3, "undo")
        h.editor.transact { $0.update(second, as: Relay.self) { $0.props.stands = [] } }
        expectEqual(publishing.standIns(for: plaque).count, 2, "a stand-in re-pointed")
        h.provide(lens, "what", [])
        expectEqual(publishing.standIns(for: plaque).count, 1, "an answer provided, with no commit")
        expect(publishing.isHeld(plaque))
        expectEqual(h.chip(of: plaque), nil, "still nothing")
    },
    test("an arrow-like link into a stand-in is no stand-in: one thing still holds the shape") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame)), other = h.add(Plaque(CGRect(x: 400, y: 100, width: 50, height: 50)))
        let holder = h.hold([plaque])
        h.add(CanvasTesting.Link(from: other, to: holder))
        expectEqual(try require(h.editor.publishing).standIns(for: plaque), [holder])
    },
    test("with a title of any length the chip keeps its one face and its place, and the title has the rest of the row") {
        let h = try publishingHarness([stubTitle], before: [stubLock])
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        let alone = try require(h.chip(of: plaque))
        for length in 1...40 {
            h.name(plaque, String(repeating: "W", count: length))
            let chip = try require(h.chip(of: plaque))
            expectEqual(chip.label.systemImage, "eye.slash", "at \(length)")
            expectEqual(chip.label.text, nil, "at \(length)")
            expectEqual(chip.rect, alone.rect, "the same place at \(length)")
            if let pill = h.editor.adornmentFrames(of: plaque).first(where: { $0.adornment == .of(StubTitle.self) }) {
                expect(pill.rect.maxX <= chip.rect.minX - AdornmentLayout.spacing, "the title stops short of the chip at \(length)")
            }
        }
    },
    test("zoomed out to 50%, the title shows from the least room beside the eye and the lock, and the eye is the same at every width") {
        let h = try publishingHarness([stubTitle], before: [stubLock])
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        h.name(plaque, "Payments roadmap")
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)
        @MainActor func title(atWidth viewPoints: CGFloat) throws -> (pill: AdornmentFrame?, chip: AdornmentFrame) {
            h.editor.transact { $0.update(plaque, as: Plaque.self) { $0.props.frame.size.width = viewPoints * 2 } }
            let pill = h.editor.adornmentFrames(of: plaque).first { $0.adornment == .of(StubTitle.self) }
            return (pill, try require(h.chip(of: plaque)))
        }
        let wide = try title(atWidth: 300)
        let eye = wide.chip.rect.width / 2
        let lock = try require(h.editor.adornmentFrames(of: plaque).first { $0.adornment == .of(StubLock.self) }).rect.width / 2
        let gap = AdornmentLayout.spacing
        let titleFrom = AdornmentLayout.minTextRoom + gap + eye + gap + lock
        for width in stride(from: CGFloat(10), through: 300, by: 1) {
            let (pill, chip) = try title(atWidth: width)
            expectEqual(chip.label.systemImage, "eye.slash", "at \(width)")
            expectEqual(chip.rect.width / 2, eye, "one face at \(width)")
            expectEqual(pill != nil, width >= titleFrom, "the title shows from \(titleFrom) points: at \(width)")
        }
    },
])

// Clicking the chip. A click on a private shape's makes it public, and the chip shows the open eye for
// 1.5 s (longer while the pointer's on it), then fades over 0.3 s, a frame every 16 ms; a click during
// that makes it private again, unless something has come to stand for it meanwhile: then it is refused.

@MainActor let chipClickTests = Suite("Clicking the private chip", [
    test("with the keys alone: ⌥Tab reaches the chip, Space makes the shape public, and the open eye that fades is no part, so the focus is the shape's again") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        h.editor.selection = plaque
        expect(h.key(Chord.optionTab))
        expectEqual(h.editor.focusedPart?.title, "Private", "named for VoiceOver as the state it shows")
        expect(h.key(Chord.space))
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil)
        expectEqual(h.editor.undoHistory.undoName, "Make Public")
        expectEqual(h.chipSymbol(of: plaque), "eye", "it shows")
        expect(!h.editor.hasFocusedPart, "but its click has a command: Make Private")
        expectEqual(h.editor.selectedShapeIDs, [plaque])
    },
    test("a click makes the shape public, in one step named Make Public; the eye opens, and a click on that makes it private again") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        h.click(at: try h.chipPoint(of: plaque))
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil)
        expectEqual(h.editor.undoHistory.undoName, "Make Public")
        h.move(to: elsewhere)
        let chip = try require(h.chip(of: plaque))
        expectEqual(chip.label.systemImage, "eye")
        expectEqual(chip.label.opacity, 1)
        h.click(at: try h.chipPoint(of: plaque))
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true)
        expectEqual(h.editor.undoHistory.undoName, "Make Private")
        h.move(to: elsewhere)
        h.wait(3000)
        expectEqual(h.chipSymbol(of: plaque), "eye.slash", "private, as it was, and it stays")
    },
    test("the open eye lingers 1.5 s, fades over 0.3 s and goes; a click where it was is then a click on the canvas") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        h.click(at: try h.chipPoint(of: plaque))
        let point = try h.chipPoint(of: plaque)
        h.move(to: elsewhere)
        h.wait(1380)                                                                     // 1.4 s after the click
        expectEqual(h.chip(of: plaque)?.label.opacity, 1, "still full")
        h.wait(100 + 150)                                                                // 150 ms into the fade
        let fading = try require(h.chip(of: plaque)).label.opacity
        expect(fading > 0.2 && fading < 0.8, "halfway: \(fading)")
        h.wait(400)
        expectEqual(h.chip(of: plaque), nil, "gone")
        h.click(at: point)
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil, "nothing to click: it stays public")
    },
    test("while the pointer's on the open eye it stays, and it goes once the pointer leaves") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        h.click(at: try h.chipPoint(of: plaque))                                         // the pointer stays on it
        h.wait(3000)
        expectEqual(h.chipSymbol(of: plaque), "eye", "still there")
        expectEqual(h.chip(of: plaque)?.label.opacity, 1)
        h.move(to: elsewhere)
        h.wait(2000)
        expectEqual(h.chip(of: plaque), nil, "gone")
    },
    test("a click on the open eye of a shape something has come to stand for writes nothing, takes no step, selects nothing and shakes the shape") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let plaque = h.add(Plaque(plaqueFrame)), other = h.add(Plaque(CGRect(x: 400, y: 100, width: 100, height: 100)))
        h.conceal(plaque)
        h.click(at: try h.chipPoint(of: plaque))                                         // public, the pointer on the open eye
        h.hold([plaque])
        h.editor.selection = other
        let before = h.editor.document
        let step = h.editor.undoHistory.undoName
        h.click(at: try h.chipPoint(of: plaque))
        expectEqual(h.editor.document, before, "nothing written")
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        expectEqual(h.editor.selection, other, "a button: the selection stays")
        expectEqual(log.refusals, [[plaque]], "refused once, to the shape")
        h.wait(16)
        expect(h.editor.drawingOffset(of: plaque) != .zero, "shaking")
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil, "it stays public")
    },
    test("held by a dynamic stand-in too: the answer holds it, and when the answer goes the open eye's click makes it private") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        h.click(at: try h.chipPoint(of: plaque))                                         // public, the pointer on the open eye
        let lens = h.lens("what", answering: [plaque])
        h.click(at: try h.chipPoint(of: plaque))
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil, "held")
        h.wait(1000)
        h.provide(lens, "what", [], revision: 2)
        h.click(at: try h.chipPoint(of: plaque))
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true)
    },
    test("Make Private refused switches the panel, when it's showing that shape alone, to Connections; nothing else changes") {
        let h = try publishingHarness([NeighborDetailsPlugin()])
        let plaque = h.add(Plaque(plaqueFrame)), other = h.add(Plaque(CGRect(x: 400, y: 100, width: 100, height: 100)))
        h.hold([plaque, other])
        let panel = try require(h.editor.detailPanel)
        let tab = DetailTabID.of(NeighborsTab.self)
        @MainActor func current(_ id: ShapeID) -> DetailTabID? {
            let record = h.editor.document[id]!
            return panel.currentTab(in: panel.layout(for: record), for: record.kind)
        }
        expect(panel.layout(for: h.editor.document[plaque]!).tabs.contains(tab), "Connections is on the shape, held or not")
        expect(current(plaque) != tab, "the plaque's own tab first")
        h.editor.selection = other
        expectEqual(h.editor.makePrivate([plaque]), [plaque], "refused")
        expect(current(plaque) != tab, "the panel shows another shape: nothing to switch")
        h.editor.selectedShapeIDs = [plaque, other]
        expectEqual(h.editor.makePrivate([plaque]), [plaque])
        expect(current(plaque) != tab, "the panel shows no one shape: nothing to switch")
        expect(current(other) != tab)
        h.editor.selection = plaque
        expectEqual(h.editor.makePrivate([plaque]), [plaque])
        expectEqual(h.editor.selection, plaque)
        expectEqual(current(plaque), tab, "Connections")
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil)
    },
    test("a locked private shape: its chip's click is refused by the core, with no step, and it shakes") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        h.editor.freeze([plaque])
        let step = h.editor.undoHistory.undoName
        h.click(at: try h.chipPoint(of: plaque))
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true, "locked, so it stays private")
        expectEqual(log.refusals.last, [plaque], "refused as read-only")
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        h.wait(16)
        expect(h.editor.drawingOffset(of: plaque) != .zero, "shaking")
    },
    test("a chip that comes with a commit under a still pointer is hovered at once, and the pointing hand shows over it") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        let point = try h.chipPoint(of: plaque)
        h.publish(plaque)
        h.move(to: elsewhere)
        h.wait(3000)
        expectEqual(h.chip(of: plaque), nil, "public again, the open eye gone")
        h.move(to: point)
        h.conceal(plaque)
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(PrivateChip.self, on: plaque)))
        expectEqual(h.editor.cursor, .pointingHand)
    },
])
