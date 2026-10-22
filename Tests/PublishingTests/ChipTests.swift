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
    /// The public chip as it's laid out now on a shape, if it shows.
    func chip(of id: ShapeID) -> AdornmentFrame? {
        editor.adornmentFrames(of: id).first { $0.adornment == .of(PublicChip.self) }
    }

    /// The middle of the chip, in view points: where a click on it lands.
    func chipPoint(of id: ShapeID) throws -> CGPoint {
        let rect = try require(chip(of: id), "a chip on the shape").rect
        return view(CGPoint(x: rect.midX, y: rect.midY))
    }

    /// What the chip says, "" when it shows only a symbol, nil without one.
    func chipText(of id: ShapeID) -> String? { chip(of: id).map { $0.label.text ?? "" } }
}

/// Out of the way of any chip, for the pointer.
let elsewhere = CGPoint(x: 600, y: 20)

@MainActor let chipTests = Suite("The public chip", [
    test("a public shape has a chip, Public with a globe, 4 points left of the lock's; a private one has none") {
        let h = try publishingHarness([stubTitle], before: [stubLock])
        let plaque = h.add(Plaque(plaqueFrame))
        expectEqual(h.chip(of: plaque), nil, "private: none")
        h.publish(plaque)
        let chip = try require(h.chip(of: plaque))
        expectEqual(chip.label.text, "Public")
        expectEqual(chip.label.systemImage, "globe")
        expect(chip.label.hasBrightSymbol, "the globe in full white, as the text is")
        let lock = try require(h.editor.adornmentFrames(of: plaque).first { $0.adornment == .of(StubLock.self) })
        expectEqual(chip.rect.maxX, lock.rect.minX - 4, "beside the lock, which is nearest the end")
        expectEqual(lock.rect.maxX, plaqueFrame.maxX)
        expectEqual(chip.rect.minY, lock.rect.minY, "in its row")
        expect(chip.label.compactFace != nil, "a compact face to fall back on")
    },
    test("every face of the chip, full and compact, has its globe in full white: public, counted, and Private lingering and fading") {
        let h = try publishingHarness([stubTitle], before: [stubLock])
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        @MainActor func expectBright(_ message: String) {
            let label = h.chip(of: plaque)?.label
            expect(label?.hasBrightSymbol == true, "\(message): the full face's globe")
            expectEqual(label?.compactFace?.systemImage, "globe", "\(message): the compact face's symbol")
            expect(label?.compactFace?.hasBrightSymbol == true, "\(message): the compact face's globe")
        }
        expectBright("public, nothing standing for it")                              // the globe alone
        let holder = h.hold([plaque])
        expectBright("public, counted")                                              // "1" with the globe
        expectEqual(h.chip(of: plaque)?.label.compactFace?.text, "1")
        h.editor.transact { $0.delete([holder]) }
        h.click(at: try h.chipPoint(of: plaque))
        h.move(to: elsewhere)
        expectEqual(h.chipText(of: plaque), "Private")
        expectBright("Private lingering")
        h.wait(1380 + 100 + 150)
        let fading = try require(h.chip(of: plaque)).label.opacity
        expect(fading < 1, "fading: \(fading)")
        expectBright("Private fading")
    },
    test("a seal (always public), a draft (never) and a stand-in have no chip: nothing to toggle") {
        let h = try publishingHarness([stubTitle], before: [stubLock])
        let seal = h.add(Seal(plaqueFrame)), draft = h.add(Draft(plaqueFrame)), holder = h.hold([seal])
        for id in [seal, draft, holder] {
            expectEqual(h.chip(of: id), nil)
            expect(h.editor.adornmentFrames(of: id).contains { $0.adornment == .of(StubLock.self) }, "the others' chips are still there")
        }
    },
    test("below 35%, where shapes are skeletons, no chip is laid out, so a click where it would be changes nothing; at 35% it's there") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(CGRect(x: 100 / 0.3, y: 100 / 0.3, width: 150 / 0.3, height: 100 / 0.3)))
        h.publish(plaque)
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expectEqual(h.editor.adornmentFrames(of: plaque), [], "none laid out")
        expectEqual(h.chip(of: plaque), nil)
        h.editor.skeletonZoom = 0.2
        expect(h.chip(of: plaque) != nil, "in full at 30%")
    },
    test("the chip counts what stands for the shape, direct or dynamic: Public · 3") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        expectEqual(h.chipText(of: plaque), "Public")
        let first = h.hold([plaque])
        expectEqual(h.chipText(of: plaque), "Public · 1")
        let second = h.add(Relay(plaqueFrame, stands: [Citation(plaque)]))
        let lens = h.lens("what", answering: [plaque])
        expectEqual(h.chipText(of: plaque), "Public · 3", "a direct stand-in of each kind and a dynamic one")
        h.editor.transact { $0.delete([first]) }
        expectEqual(h.chipText(of: plaque), "Public · 2")
        h.editor.undo()
        expectEqual(h.chipText(of: plaque), "Public · 3", "undo")
        h.editor.transact { $0.update(second, as: Relay.self) { $0.props.stands = [] } }
        expectEqual(h.chipText(of: plaque), "Public · 2", "a stand-in re-pointed")
        h.provide(lens, "what", [])
        expectEqual(h.chipText(of: plaque), "Public · 1", "an answer provided, with no commit")
        h.provide(lens, "what", [plaque], revision: 2)
        expectEqual(h.chipText(of: plaque), "Public · 2")
    },
    test("an arrow-like link into a stand-in is no stand-in: the count stays") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame)), other = h.add(Plaque(CGRect(x: 400, y: 100, width: 50, height: 50)))
        h.publish(plaque)
        let holder = h.hold([plaque])
        h.add(CanvasTesting.Link(from: other, to: holder))
        expectEqual(h.chipText(of: plaque), "Public · 1")
    },
    test("with a title, the chip takes its compact face as soon as the full one would leave the title cut short, and keeps it for every longer title") {
        let h = try publishingHarness([stubTitle], before: [stubLock])
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        h.hold([plaque])
        h.hold([plaque])
        h.hold([plaque])
        var compact: [Int] = []
        for length in 1...40 {
            h.name(plaque, String(repeating: "W", count: length))
            let chip = try require(h.chip(of: plaque))
            if chip.label.text == "3" { compact.append(length) } else { expectEqual(chip.label.text, "Public · 3", "full at \(length)") }
        }
        expect(!compact.isEmpty, "some title lengths take the compact face: \(compact)")
        expect(compact.first! > 1, "not for a short title: the full chip leaves it room whole")
        expectEqual(compact, Array(compact.first!...40), "from the first the full chip would cut short to every longer one: it changes once")
        h.name(plaque, String(repeating: "W", count: compact.first!))
        let lone = try require(h.editor.adornmentFrames(of: plaque).first { $0.adornment == .of(PublicChip.self) })
        expectEqual(lone.label.systemImage, "globe", "with its globe")
    },
    test("zoomed out to 50%, the chip is compact from the narrowest shape until the full chip and the whole title fit together, and full after: it changes once") {
        // "Payments roadmap" on a public shape three things stand for, with a lock, as the shape widens. The
        // full chip ("Public · 3") is 78 points, the compact (the globe and 3) 36, the lock 18, the title
        // whole 117, the room a title needs 30, the gap between them 4.
        let h = try publishingHarness([stubTitle], before: [stubLock])
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        h.hold([plaque])
        h.hold([plaque])
        h.hold([plaque])
        h.name(plaque, "Payments roadmap")
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)
        @MainActor func title(atWidth viewPoints: CGFloat) throws -> (pill: AdornmentFrame?, chip: AdornmentFrame) {
            h.editor.transact { $0.update(plaque, as: Plaque.self) { $0.props.frame.size.width = viewPoints * 2 } }
            let pill = h.editor.adornmentFrames(of: plaque).first { $0.adornment == .of(StubTitle.self) }
            return (pill, try require(h.chip(of: plaque)))
        }
        // What each is, in view points, measured: the whole title and the full chip beside it, the compact chip, the lock.
        let wide = try title(atWidth: 300)
        expectEqual(wide.chip.label.text, "Public · 3", "wide: the full chip, the whole title")
        let (whole, full) = (try require(wide.pill).rect.width / 2, wide.chip.rect.width / 2)
        let compactChip = try title(atWidth: 180).chip
        expectEqual(compactChip.label.text, "3")
        let compactWidth = compactChip.rect.width / 2
        let lock = try require(h.editor.adornmentFrames(of: plaque).first { $0.adornment == .of(StubLock.self) }).rect.width / 2
        let gap = AdornmentLayout.spacing
        // The title shows from the least room beside the compact chip; the chip is compact until the whole title and the full chip fit together.
        let titleFrom = AdornmentLayout.minTextRoom + gap + compactWidth + gap + lock
        let fullFrom = whole + gap + full + gap + lock
        expectEqual([titleFrom, fullFrom], [92, 221], "the boundaries, in view points")
        var faces: [Bool] = []                                                        // compact, at each width
        for width in stride(from: CGFloat(10), through: 300, by: 1) {
            let (pill, chip) = try title(atWidth: width)
            let isCompact = chip.label.text == "3"
            faces.append(isCompact)
            expectEqual(pill != nil, width >= titleFrom, "the title shows from \(titleFrom) points: at \(width)")
            // Compact whether or not a title shows: it's the most room, and the face doesn't change as the shape narrows.
            expectEqual(isCompact, width < fullFrom, "compact below \(fullFrom): at \(width)")
            if let pill, isCompact { expect(pill.rect.width <= whole * 2, "never wider than the title: \(width)") }
        }
        let toFull = zip(faces, faces.dropFirst()).filter { $0 && !$1 }.count
        let toCompact = zip(faces, faces.dropFirst()).filter { !$0 && $1 }.count
        expectEqual(faces.first, true, "compact from the narrowest")
        expectEqual(faces.last, false)
        expectEqual(toFull, 1, "compact to full once across the sweep")
        expectEqual(toCompact, 0, "and never back: one change in all")
        // The cases the sweep passes through: cut short where it would have vanished, cut short where the full
        // chip would have cut it, whole beside the compact chip, whole beside the full one.
        let vanished = try title(atWidth: 95)
        expectEqual(vanished.chip.label.text, "3")
        let shown = try require(vanished.pill, "the title, where it vanished")
        expect(shown.rect.width / 2 >= AdornmentLayout.minTextRoom && shown.rect.width / 2 < whole, "cut short: \(shown.rect.width)")
        expectEqual(vanished.chip.rect.minX - shown.rect.maxX, gap * 2, "4 points before the chip, in world units at 50%")
        expectEqual(try title(atWidth: 91).pill, nil, "a point under it, no title, and the chip is compact all the same")
        expectEqual(try title(atWidth: 91).chip.label.text, "3")
        expectEqual(try title(atWidth: 60).chip.label.text, "3")
        let cut = try title(atWidth: 140)
        expectEqual(cut.chip.label.text, "3", "where the full chip would have cut the title short, the compact one gives it more room")
        expect(try require(cut.pill).rect.width > (try require(vanished.pill)).rect.width)
        expectEqual(try title(atWidth: 180).chip.label.text, "3")
        expectEqual(try require(try title(atWidth: 180).pill).rect.width / 2, whole, "whole beside the compact chip")
        expectEqual(try title(atWidth: 221).chip.label.text, "Public · 3", "the first width the full chip and the whole title fit together")
    },
    test("unreferenced, the compact face is the globe alone") {
        let h = try publishingHarness([stubTitle], before: [stubLock])
        let plaque = h.add(Plaque(CGRect(x: 100, y: 100, width: 80, height: 100)))
        h.publish(plaque)
        h.name(plaque, "W")
        expectEqual(h.chipText(of: plaque), "", "a short title beside the globe: the disc, no text")
        expectEqual(h.chip(of: plaque)?.label.systemImage, "globe")
        h.name(plaque, nil)
        expectEqual(h.chipText(of: plaque), "Public", "no title: room for the words")
    },
])

// Clicking the chip. A click on a public shape's makes it private, and the chip reads Private for
// 1.5 s (longer while the pointer's on it), then fades over 0.3 s, a frame every 16 ms; a click
// during that makes it public again. A click while anything stands for the shape is refused.

@MainActor let chipClickTests = Suite("Clicking the public chip", [
    test("a click makes the shape private, in one step named Make Private; the chip reads Private, and a click on that makes it public again") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        h.click(at: try h.chipPoint(of: plaque))
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], nil)
        expectEqual(h.editor.undoHistory.undoName, "Make Private")
        h.move(to: elsewhere)
        let chip = try require(h.chip(of: plaque))
        expectEqual(chip.label.text, "Private")
        expectEqual(chip.label.systemImage, "globe")
        expectEqual(chip.label.opacity, 1)
        h.click(at: try h.chipPoint(of: plaque))
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], true)
        expectEqual(h.editor.undoHistory.undoName, "Make Public")
        h.move(to: elsewhere)
        h.wait(3000)
        expectEqual(h.chipText(of: plaque), "Public", "public, as it was, and it stays")
    },
    test("Private lingers 1.5 s, fades over 0.3 s and goes; a click where it was is then a click on the canvas") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        h.click(at: try h.chipPoint(of: plaque))
        let point = try h.chipPoint(of: plaque)
        h.move(to: elsewhere)
        h.wait(1380)                                                                     // 1.4 s after the click
        expectEqual(h.chip(of: plaque)?.label.opacity, 1, "still full")
        h.wait(100 + 150)                                                                // 150 ms into the fade
        let fading = try require(h.chip(of: plaque)).label.opacity
        expect(fading > 0.2 && fading < 0.8, "halfway: \(fading)")
        expect(h.chip(of: plaque)?.label.compactFace?.opacity == fading, "its compact face fades with it")
        h.wait(400)
        expectEqual(h.chip(of: plaque), nil, "gone")
        h.click(at: point)
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], nil, "nothing to click")
    },
    test("while the pointer's on Private it stays, and it goes once the pointer leaves") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        h.click(at: try h.chipPoint(of: plaque))                                         // the pointer stays on it
        h.wait(3000)
        expectEqual(h.chipText(of: plaque), "Private", "still there")
        expectEqual(h.chip(of: plaque)?.label.opacity, 1)
        h.move(to: elsewhere)
        h.wait(2000)
        expectEqual(h.chip(of: plaque), nil, "gone")
    },
    test("a click on a held shape's chip writes nothing, takes no step, and shakes the shape") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        h.hold([plaque])
        let before = h.editor.document
        let step = h.editor.undoHistory.undoName
        h.click(at: try h.chipPoint(of: plaque))
        h.move(to: elsewhere)
        expectEqual(h.editor.document, before, "nothing written")
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        expectEqual(log.refusals, [[plaque]], "refused once, to the shape")
        h.wait(16)
        expect(h.editor.drawingOffset(of: plaque) != .zero, "shaking")
        h.wait(1000)
        expectEqual(h.chipText(of: plaque), "Public · 1", "it stays public, and says why")
    },
    test("held by a dynamic stand-in too: the answer holds it, and when the answer goes the chip makes it private") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        let lens = h.lens("what", answering: [plaque])
        h.click(at: try h.chipPoint(of: plaque))
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], true, "held")
        h.wait(1000)
        h.provide(lens, "what", [], revision: 2)
        h.click(at: try h.chipPoint(of: plaque))
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], nil)
    },
    test("the refused click switches the panel, when it's showing that shape alone, to Connections; nothing else changes") {
        let h = try publishingHarness([NeighborDetailsPlugin()])
        let plaque = h.add(Plaque(plaqueFrame)), other = h.add(Plaque(CGRect(x: 400, y: 100, width: 100, height: 100)))
        h.publish(plaque, other)
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
        h.click(at: try h.chipPoint(of: plaque))                                         // selects nothing: it's a button
        expectEqual(h.editor.selection, other, "the selection stays")
        expect(current(plaque) != tab, "the panel shows another shape: nothing to switch")
        h.move(to: elsewhere)
        h.wait(1000)
        h.editor.selectedShapeIDs = [plaque, other]
        h.click(at: try h.chipPoint(of: plaque))
        expectEqual(h.editor.selectedShapeIDs, [plaque, other], "the selection stays")
        expect(current(plaque) != tab, "the panel shows no one shape: nothing to switch")
        expect(current(other) != tab)
        h.move(to: elsewhere)
        h.wait(1000)
        h.editor.selection = plaque
        h.click(at: try h.chipPoint(of: plaque))
        expectEqual(h.editor.selection, plaque)
        expectEqual(current(plaque), tab, "Connections")
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], true)
    },
    test("a locked shape: its chip click is refused by the core, whether held or not, with no step") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let free = h.add(Plaque(plaqueFrame)), held = h.add(Plaque(CGRect(x: 400, y: 100, width: 100, height: 100)))
        h.publish(free, held)
        h.hold([held])
        h.editor.freeze([free, held])
        let step = h.editor.undoHistory.undoName
        h.click(at: try h.chipPoint(of: free))
        expectEqual(h.editor.document[free]?[PublicProperty.self], true, "locked, so it stays public")
        expectEqual(log.refusals.last, [free], "refused as read-only")
        h.wait(1000)
        h.click(at: try h.chipPoint(of: held))
        expectEqual(h.editor.document[held]?[PublicProperty.self], true)
        expectEqual(log.refusals.last, [held])
        expectEqual(h.editor.undoHistory.undoName, step, "no step either way")
        h.wait(16)
        expect(h.editor.drawingOffset(of: held) != .zero, "shaking")
    },
    test("a chip that comes with a commit under a still pointer is hovered at once, and the pointing hand shows over it") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.move(to: CGPoint(x: 230, y: 82))
        h.publish(plaque)
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(PublicChip.self, on: plaque)))
        expectEqual(h.editor.cursor, .pointingHand)
    },
])
