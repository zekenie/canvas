import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TestKit

// Pressing a frame: hollow. A frame that holds shapes is its border, 6 view points either side of
// its edge, and its title's pill; its inside is the canvas. One that holds nothing is pressed
// anywhere inside too. The camera starts at the origin at 100%, so view points are world units until
// a test zooms.

@MainActor let hitTests = Suite("Pressing a frame", [
    test("holding a shape, it's hit on its border, 6 view points either side of its edge, and nowhere inside but on what it holds") {
        let h = try frameHarness()
        let frame = h.addFrame()
        let box = h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100), in: frame)
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 300, y: 100)), frame, "on its top edge")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 300, y: 95)), frame, "5 outside it")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 300, y: 105)), frame, "5 inside it")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 300, y: 93)), nil, "7 outside: the canvas")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 300, y: 107)), nil, "7 inside: the canvas")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 504, y: 250)), frame, "its right edge")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 300, y: 397)), frame, "its bottom edge")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 103, y: 380)), frame, "its left edge")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 400, y: 300)), nil, "its empty inside")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 200, y: 200)), box, "what it holds")
        expectEqual(h.editor.shape(at: CGPoint(x: 400, y: 300)), nil, "for everything that finds shapes by point, not only the select tool")
    },
    test("the border's reach is view points: zoomed out it reaches further in world units, zoomed in less") {
        let h = try frameHarness()
        let frame = h.addFrame()
        h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100), in: frame)
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)
        expectEqual(h.editor.shape(at: CGPoint(x: 300, y: 111)), frame, "11 units in at 50%: 5.5 view points")
        expectEqual(h.editor.shape(at: CGPoint(x: 300, y: 113)), nil, "13 units in: 6.5")
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        expectEqual(h.editor.shape(at: CGPoint(x: 300, y: 102.5)), frame, "2.5 units in at 200%: 5 view points")
        expectEqual(h.editor.shape(at: CGPoint(x: 300, y: 103.5)), nil, "3.5 units in: 7")
        expectEqual(h.editor.shape(at: CGPoint(x: 300, y: 97.5)), frame, "2.5 units out: 5 view points")
        expectEqual(h.editor.shape(at: CGPoint(x: 300, y: 96.5)), nil, "3.5 units out: 7")
    },
    test("holding nothing, it's hit anywhere inside, and its border's reach outside it; holding something again, hollow again") {
        let h = try frameHarness()
        let frame = h.addFrame()
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 300, y: 250)), frame, "its empty inside")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 300, y: 95)), frame, "5 outside its edge")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 300, y: 93)), nil)
        let box = h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100), in: frame)
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 300, y: 250)), nil, "holding a box")
        h.editor.transact { $0.delete([box]) }
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 300, y: 250)), frame, "empty again")
    },
    test("its pill grabs it, an untitled one's too; for the select tool, not for what finds shapes by their own outline") {
        let h = try frameHarness()
        let frame = h.addFrame()
        let box = h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100), in: frame)
        let pill = try require(h.editor.adornmentFrames(of: frame).first?.rect)
        let middle = CGPoint(x: pill.midX, y: pill.midY)
        expectEqual(h.editor.selectableShape(at: middle), frame)
        expectEqual(h.editor.shape(at: middle), nil)
        h.press(at: middle)
        h.drag(to: middle + CGPoint(x: 30, y: 40))
        h.drag(to: middle + CGPoint(x: 60, y: 80))
        h.release()
        expectEqual(h.editor.box(frame)?.origin, frameRect.origin + CGPoint(x: 60, y: 80), "dragged by its pill")
        expectEqual(h.editor.box(box)?.origin, CGPoint(x: 210, y: 230), "and what it holds with it")
    },
    test("a press on its empty inside is the canvas: a click deselects, and a drag is a marquee that selects what it holds, not the frame") {
        let h = try frameHarness()
        let frame = h.addFrame()
        let box = h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100), in: frame)
        h.editor.selection = frame
        h.click(at: CGPoint(x: 400, y: 300))
        expectEqual(h.editor.selectedShapeIDs, [], "a click on its inside deselects")
        h.press(at: CGPoint(x: 120, y: 130))
        h.drag(to: CGPoint(x: 200, y: 200))
        h.drag(to: CGPoint(x: 300, y: 300))
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [box], "the marquee, inside it, selects what it holds")
        expectEqual(h.editor.box(frame), frameRect, "and nothing moved")
    },
    test("a press on its border grabs it: a drag moves it, and what it holds with it") {
        let h = try frameHarness()
        let frame = h.addFrame()
        let box = h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100), in: frame)
        h.press(at: CGPoint(x: 300, y: 102))
        h.drag(to: CGPoint(x: 330, y: 132))
        h.drag(to: CGPoint(x: 350, y: 152))
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [frame])
        expectEqual(h.editor.box(frame)?.origin, CGPoint(x: 150, y: 150))
        expectEqual(h.editor.box(box)?.origin, CGPoint(x: 200, y: 200))
        expectEqual(h.editor.undoHistory.undoName, "Move")
    },
    test("hover follows the same test: its border and its pill hover it, its inside hovers nothing") {
        let h = try frameHarness()
        let frame = h.addFrame()
        h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100), in: frame)
        h.move(to: CGPoint(x: 400, y: 300))
        expectEqual(h.editor.hovered, nil, "its inside")
        h.move(to: CGPoint(x: 300, y: 101))
        expectEqual(h.editor.hovered, frame, "its border")
        h.move(to: CGPoint(x: 400, y: 300))
        expectEqual(h.editor.hovered, nil)
        let pill = try require(h.editor.adornmentFrames(of: frame).first?.rect)
        h.move(to: CGPoint(x: pill.midX, y: pill.midY))
        expectEqual(h.editor.hovered, frame, "its pill")
    },
    test("the marquee selects it when it reaches its edge or holds it whole, never when it's drawn wholly inside it") {
        let h = try frameHarness()
        let frame = h.addFrame()
        let box = h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100), in: frame)
        @MainActor func brush(_ from: CGPoint, _ to: CGPoint) -> Set<ShapeID> {
            h.editor.selectedShapeIDs = []
            h.press(at: from)
            h.drag(to: (from + to) / 2)
            h.drag(to: to)
            h.release()
            return Set(h.editor.selectedShapeIDs)
        }
        expectEqual(brush(CGPoint(x: 120, y: 120), CGPoint(x: 480, y: 380)), [box], "wholly inside it: what it holds")
        expectEqual(brush(CGPoint(x: 400, y: 300), CGPoint(x: 560, y: 450)), [frame], "across its corner")
        expectEqual(brush(CGPoint(x: 140, y: 140), CGPoint(x: 520, y: 380)), [frame, box], "across its right edge, over the box")
        expectEqual(brush(CGPoint(x: 50, y: 50), CGPoint(x: 560, y: 450)), [frame, box], "holding it whole")
    },
])
