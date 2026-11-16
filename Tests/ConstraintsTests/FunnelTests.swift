import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import DetailPanel
import Selection
import TestKit
import Titles
import Validation

// The funnel chip: a symbol in a disc in the row above a container's top-left corner once a constraint applies, red with how
// many shapes break one when some do, its tooltip the words as typed, a click selecting the container and choosing its Rules
// tab, a part ⌥Tab reaches and Return presses, named for VoiceOver, none zoomed out.

private let penRect = CGRect(x: 100, y: 100, width: 400, height: 300)

extension EditorHarness {
    /// The funnel chip a container shows now.
    func funnel(of id: ShapeID) -> AdornmentFrame? {
        editor.adornmentFrames(of: id).first { $0.adornment == .of(ConstraintFunnel.self) }
    }
}

@MainActor let funnelTests = Suite("Constraints: the funnel chip", [
    test("on a container too narrow for its title and the funnel, the funnel is left out, as any chip with no room is; the menu and the rings still show") {
        let h = try constraintHarness()
        let narrow = h.corral("Backlog for the next quarter sprint", CGRect(x: 100, y: 100, width: 120, height: 200), [onlyTiles])
        expectEqual(h.funnel(of: narrow), nil, "no room: left out, not squeezed")
        let wide = h.corral("Backlog", CGRect(x: 400, y: 100, width: 300, height: 200), [onlyTiles])
        expect(h.funnel(of: wide) != nil, "room for it")
        h.editor.selectedShapeIDs = [narrow]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 150, y: 200)))
        expect(menu.outline.contains("  Show Constraints"), "Show Constraints is in the menu: \(menu.outline)")
    },
    test("none while no constraint applies; a symbol alone once one does, neutral while every shape fits; gone with the last constraint") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect)
        expectEqual(h.funnel(of: pen), nil)
        h.writer.add(onlyTiles, to: .shape(pen))
        let funnel = try require(h.funnel(of: pen))
        expectEqual(funnel.label.systemImage, ConstraintsStyle.funnelSymbol)
        expectEqual(funnel.label.text, nil, "the symbol alone")
        expectEqual(funnel.label.tint, nil, "neutral")
        expect(funnel.rect.minY < penRect.minY, "above the top edge: \(funnel.rect)")
        let pill = try require(h.editor.adornmentFrames(of: pen).first { $0.adornment == .of(TitlePill.self) })
        expect(funnel.rect.minX >= pill.rect.maxX, "after the title's pill: \(funnel.rect) \(pill.rect)")
        h.writer.remove(onlyTiles, from: .shape(pen))
        expectEqual(h.funnel(of: pen), nil)
        let plain = h.disc(at: CGPoint(x: 700, y: 100))
        expectEqual(h.funnel(of: plain), nil, "a shape that holds none has no funnel")
    },
    test("red with the count of the shapes inside that break one, as they come and go") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        var label = try require(h.funnel(of: pen)).label
        expectEqual(label.text, "1")
        expectEqual(label.systemImage, ConstraintsStyle.funnelSymbol)
        expectEqual(label.tint?.color, Severity.error.color, "red as Validation draws an error")
        h.disc(at: CGPoint(x: 300, y: 300), in: pen)
        h.tile("T", at: CGPoint(x: 150, y: 150), in: pen)
        h.settle()
        label = try require(h.funnel(of: pen)).label
        expectEqual(label.text, "2", "the tile fits")
        h.editor.transact { $0.delete([d]) }
        h.settle()
        expectEqual(try require(h.funnel(of: pen)).label.text, "1")
        h.writer.remove(noDiscs, from: .shape(pen))
        h.settle()
        expectEqual(h.funnel(of: pen), nil)
    },
    test("a pocket has one, for its board's top level; what a container has from elsewhere counts") {
        let given = Given()
        let h = try constraintHarness(given)
        let drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150), [noDiscs])
        expect(h.funnel(of: drawer) != nil)
        let pen = h.corral("Pen", penRect)
        expectEqual(h.funnel(of: pen), nil)
        given.lists[pen] = [ConstraintSource(holder: ShapeID(), constraints: [onlyTiles])]
        h.index.inheritedConstraintsDidChange(of: [pen])
        h.wait(0)
        expect(h.funnel(of: pen) != nil, "a list from elsewhere")
    },
    test("the tooltip says what it accepts, the words as typed, each once, and how many don't fit") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles, noDiscs])
        h.settle()
        h.editor.setTool("select")
        let rect = try require(h.funnel(of: pen)).rect
        h.move(to: CGPoint(x: rect.midX, y: rect.midY))
        expectEqual(h.editor.pointerHelp, "Accepts: only tiles; no discs")
        h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        h.move(to: CGPoint(x: 5, y: 5))
        h.move(to: CGPoint(x: rect.midX, y: rect.midY))
        expectEqual(h.editor.pointerHelp, "Accepts: only tiles; no discs\n1 not accepted")
    },
    test("a click selects the container, one step back, and chooses its Rules tab") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles])
        let other = h.corral("Other", CGRect(x: 600, y: 100, width: 150, height: 150))
        h.editor.setTool("select")
        h.editor.selectedShapeIDs = [other]
        let rect = try require(h.funnel(of: pen)).rect
        h.move(to: CGPoint(x: rect.midX, y: rect.midY))
        h.click()
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [pen])
        expectEqual(h.editor.detailPanel?.chosenTab(for: Corral.kind), .of(RulesTab.self))
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [other], "one step back")
    },
    test("it's a part of its container: ⌥Tab reaches it, named for what it says, and Return presses it; plain and red") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs])
        h.editor.selection = pen
        expect(h.key(Chord.optionTab))
        expectEqual(h.editor.focusedPart?.title, "Constraints, no discs", "what it accepts, said")
        h.editor.selection = nil
        h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        h.editor.selection = pen
        expect(h.key(Chord.optionTab))
        expectEqual(h.editor.focusedPart?.title, "Constraints, no discs, 1 not accepted")
        h.editor.selection = nil
        h.editor.selection = pen
        expect(h.key(Chord.optionTab))
        expect(h.key(Chord.return))
        h.wait(0)
        expectEqual(h.editor.detailPanel?.chosenTab(for: Corral.kind), .of(RulesTab.self))
        expectEqual(h.editor.selectedShapeIDs, [pen])
    },
    test("VoiceOver hears what a container accepts after what it is, the first words and how many more; the funnel says the same, with how many are not accepted") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles, noDiscs, onlyGlossy])
        let plain = h.corral("Plain", CGRect(x: 600, y: 100, width: 150, height: 150))
        let said = try require(h.editor.accessibleDescription(of: pen)).label
        expect(said.hasPrefix("Pen, ") && said.hasSuffix(", accepts only tiles and 2 more"), "\(said)")
        let alone = h.corral("Alone", CGRect(x: 600, y: 300, width: 150, height: 150), [noDiscs])
        expect(try require(h.editor.accessibleDescription(of: alone)).label.hasSuffix(", accepts no discs"))
        expect(try !require(h.editor.accessibleDescription(of: plain)).label.contains("accepts"), "a container with none says nothing")
        h.editor.selection = pen
        expect(h.key(Chord.optionTab))
        expectEqual(h.editor.focusedPart?.title, "Constraints, only tiles and 2 more")
        h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        h.editor.selection = nil
        h.editor.selection = pen
        expect(h.key(Chord.optionTab))
        expectEqual(h.editor.focusedPart?.title, "Constraints, only tiles and 2 more, 1 not accepted")
        h.writer.removeAll(from: .shape(pen))
        h.settle()
        expect(try !require(h.editor.accessibleDescription(of: pen)).label.contains("accepts"), "gone with the last constraint")
    },
    test("zoomed out, where shapes are skeletons, it's gone, and so is its button") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles])
        expect(h.funnel(of: pen) != nil)
        h.zoom(to: 0.2)
        expectEqual(h.funnel(of: pen), nil)
        h.editor.selection = pen
        expect(h.key(Chord.optionTab))
        expectEqual(h.editor.focusedPart?.title, nil)
    },
])
