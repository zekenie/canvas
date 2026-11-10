import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Frames
import Geometry
import LanguageModels
import Mentions
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// A titled shape at its container's top-left keeps its pill clear of the container's tab at every zoom: at 60% a note's
// "n1" pill would sit over its frame's "f1" tab, since the tab keeps its size on screen and the inset doesn't. Any kind's
// pill, in any container with a tab: the row gives way (Adornments), never by naming a kind.

@MainActor let tabGiveWayShippedTests = Suite("Pills clear of a container's tab, as shipped", [
    test("at 60% a note at its frame's top-left has its pill past the frame's tab, light and dark; at 100% too, and where no tab meets its row, at its edge") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        var frame = ShapeRecord(Frame(frame: CGRect(x: 100, y: 100, width: 600, height: 400)))
        frame[TitleProperty.self] = "f1"
        var note = ShapeRecord(StickyNote(frame: CGRect(x: 116, y: 124, width: 200, height: 200), text: MentionText(plain: "")))
        note[TitleProperty.self] = "n1"
        h.editor.transact { $0.insert(frame); $0.insert(note) }
        h.editor.put([note.id], in: frame.id)
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        _ = renderBitmap(h.editor, size: CGSize(width: 800, height: 600))
        let full = try require(h.editor.adornmentFrames(of: note.id).first { $0.adornment.placement == .aboveTopLeft }?.rect)
        let tabAtFull = try require(h.editor.adornmentFrames(of: frame.id).first { $0.adornment.placement == .onTopEdge }?.rect)
        expect(!full.intersects(tabAtFull), "at 100% clear too: \(full) \(tabAtFull)")
        h.editor.transact { $0.update(note.id, as: StickyNote.self) { $0.props.frame.origin.y = 160 } }
        _ = renderBitmap(h.editor, size: CGSize(width: 800, height: 600))
        let clear = try require(h.editor.adornmentFrames(of: note.id).first { $0.adornment.placement == .aboveTopLeft }?.rect)
        expectEqual(clear.minX, 116, "a note far enough below the tab keeps its pill at its edge")
        h.editor.camera = Camera(origin: .zero, zoom: 0.6)
        for dark in [false, true] {
            let size = CGSize(width: 800, height: 600)
            var drawn: NSBitmapImageRep?
            if dark {
                NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { drawn = renderBitmap(h.editor, size: size) }
            } else {
                drawn = renderBitmap(h.editor, size: size)
            }
            let bitmap = try require(drawn)
            let tab = try require(h.editor.adornmentFrames(of: frame.id).first { $0.adornment.placement == .onTopEdge }?.rect, "f1's tab")
            let pill = try require(h.editor.adornmentFrames(of: note.id).first { $0.adornment.placement == .aboveTopLeft }?.rect, "n1's pill")
            expect(!pill.intersects(tab), "\(dark ? "dark" : "light"): n1's pill \(pill) clear of f1's tab \(tab)")
            expect(pill.minX >= tab.maxX, "past the tab's end")
            // Both are drawn where they were placed: their middles are not the ground's, and the pill's middle is no longer under the tab.
            @MainActor func pixel(_ rect: CGRect) -> [Int] {
                var value = [Int](repeating: 0, count: 4)
                let point = h.editor.camera.toView(CGPoint(x: rect.midX, y: rect.midY))
                bitmap.getPixel(&value, atX: Int(point.x), y: Int(point.y))
                return value
            }
            var ground = [Int](repeating: 0, count: 4)
            bitmap.getPixel(&ground, atX: 790, y: 590)
            let differs = { (a: [Int]) in zip(a, ground).prefix(3).contains { abs($0 - $1) > 8 } }
            expect(differs(pixel(tab)), "\(dark ? "dark" : "light"): f1's tab is drawn: \(pixel(tab)) on \(ground)")
            expect(differs(pixel(pill)), "\(dark ? "dark" : "light"): n1's pill is drawn: \(pixel(pill)) on \(ground)")
        }
    },
])
