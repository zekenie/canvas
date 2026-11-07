import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import CoreGraphics
import Geometry
import Selection
import TestKit

// Paste readers (`registrar.pasteReader`): text another app put on the pasteboard, read into shapes ⌘V puts down
// as it puts down this app's own, as new shapes; asked in plugin order, only when the pasteboard holds none of
// this app's shapes, the first that reads the text the paste; and a reader whose plugin's kit is off never asked.

/// What a reader was asked.
@MainActor private final class Asked {
    var texts: [String] = []
}

/// A reader of text that is a number of boxes ("3 boxes"): that many boxes, 40 square, in a row, 10 apart.
@MainActor private func boxReader(_ id: PluginID, kit: (any Kit.Type)? = nil, asked: Asked) -> Contributor {
    Contributor(id: id) { r in
        if let kit { r.join(kit) }
        r.pasteReader("boxes") { text, _ in
            asked.texts.append(text)
            guard text.hasSuffix(" boxes"), let count = Int(text.dropLast(" boxes".count)), count > 0 else { return nil }
            let boxes = (0..<count).map { AnyShapeRecord(ShapeRecord(Box(CGRect(x: CGFloat($0) * 50, y: 0, width: 40, height: 40)))) }
            return CanvasFile(root: CanvasDocument(shapes: boxes))
        }
    }
}

/// A reader of any text, which says it read none: so the readers after it are asked.
@MainActor private func refusing(_ asked: Asked) -> Contributor {
    Contributor(id: "refusing") { r in r.pasteReader("nothing") { text, _ in asked.texts.append(text); return nil } }
}

@MainActor private func setText(_ pasteboard: NSPasteboard, _ text: String) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

@MainActor let pasteReaderTests = Suite("Paste readers", [
    test("text a reader reads pastes as new shapes, centered in the view, selected, one Paste step; text none reads, nothing") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let asked = Asked()
        let h = try harness(pasteboard, [boxReader("boxes", asked: asked)])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        setText(pasteboard, "3 boxes")
        expect(h.editor.canPaste)
        h.editor.paste()
        let boxes = h.editor.document.shapes
        expectEqual(boxes.count, 3)
        expectEqual(h.editor.shapeContext.bounds(of: boxes.map(\.id))?.center, CGPoint(x: 400, y: 300), "in the middle of the view")
        expectEqual(Set(h.editor.selectedShapeIDs), Set(boxes.map(\.id)))
        expectEqual(h.editor.undoHistory.undoName, "Paste")
        expect(boxes.allSatisfy { $0.copiedFrom == nil }, "new shapes, copies of nothing")
        h.editor.paste()
        expectEqual(h.editor.document.shapes.count, 6, "pasted again, three more")
        expectEqual(Set(h.editor.document.shapes.map(\.id)).count, 6, "each its own id")
        setText(pasteboard, "a box")
        expect(!h.editor.canPaste, "text no reader reads")
        expectEqual(asked.texts, ["3 boxes", "a box"], "asked once a pasteboard")
    },
    test("Paste at Pointer and the context menu's Paste land read shapes on the pointer and the click") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [boxReader("boxes", asked: Asked())])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        setText(pasteboard, "1 boxes")
        h.editor.paste(centeredAt: CGPoint(x: 100, y: 120))
        expectEqual(h.editor.document.shapes.first?.box, CGRect(x: 80, y: 100, width: 40, height: 40))
    },
    test("readers are asked in plugin order, the first that reads the text the paste; none while this app's shapes are there") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let before = Asked(), boxes = Asked()
        let h = try harness(pasteboard, [refusing(before), boxReader("boxes", asked: boxes)])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        setText(pasteboard, "2 boxes")
        expect(h.editor.canPaste)
        expectEqual(before.texts, ["2 boxes"])
        expectEqual(boxes.texts, ["2 boxes"])
        let disc = h.add(Disc(CGRect(x: 0, y: 0, width: 40, height: 40)))
        h.editor.copy([disc])
        expect(h.editor.canPaste)
        h.editor.paste()
        expectEqual(h.editor.document.shapes.map(\.kind), [Disc.kind, Disc.kind], "this app's shape, not the text")
        expectEqual(boxes.texts, ["2 boxes"], "no reader asked")
    },
    test("a reader whose plugin's kit is off is never asked; on, it reads") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let asked = Asked()
        let h = try harness(pasteboard, [boxReader("workshop-boxes", kit: Workshop.self, asked: asked)])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        setText(pasteboard, "2 boxes")
        expect(!h.editor.canPaste)
        h.editor.paste()
        expectEqual(h.editor.document.shapes.count, 0)
        expectEqual(asked.texts, [], "never asked")
        h.editor.turn(Workshop.self, on: true)
        expect(h.editor.canPaste, "the same pasteboard, read again for the kit")
        h.editor.paste()
        expectEqual(h.editor.document.shapes.count, 2)
    },
    test("the report names each reader") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let registry = try harness(pasteboard, [boxReader("boxes", asked: Asked())]).editor.registry
        expect(registry.report.contains("paste reader boxes"), registry.report)
    },
])
