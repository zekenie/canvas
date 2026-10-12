import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Geometry
import Mentions
import StickyNotes
import TestKit
import Titles
import Types

// A type's note is white paper in the light appearance and a light paper (0.92) in the dark, in full
// and zoomed out; a plain note is its yellow in both, as it was; the text's ink is the note's on
// both; and a titled type's cover reads on the paper.

private let paperFrame = CGRect(x: 50, y: 50, width: 200, height: 200)
private let paperCanvas = CGSize(width: 300, height: 300)
/// A point in the note away from its text and its edge: its lower right.
private let paperSpot = CGPoint(x: 220, y: 220)

/// The canvas drawn in either appearance.
@MainActor private func render(_ editor: CanvasEditor, dark: Bool, size: CGSize = paperCanvas, scale: CGFloat = 1) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

/// An editor with one note, a type or not, titled or not, at `zoom`.
@MainActor private func paperEditor(isType: Bool, text: String = "", title: String? = nil, zoom: CGFloat = 1, frame: CGRect = paperFrame) throws -> (CanvasEditor, ShapeID) {
    let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
    editor.camera = Camera(origin: .zero, zoom: zoom)
    var note = ShapeRecord(StickyNote(frame: frame, text: MentionText(plain: text)))
    if isType { note[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) }
    note[TitleProperty.self] = title
    let record = AnyShapeRecord(note)
    editor.transact { $0.insert(record) }
    return (editor, record.id)
}

private let yellow = [255, 222, 115]

@MainActor private func expectPaper(_ actual: [Int], _ expected: [Int], _ what: String) {
    expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 2 }, "\(what): \(actual.prefix(3)) is not \(expected)")
}

/// How many pixels in a rect have a red channel under 90: a dark ink's glyphs.
@MainActor private func darkInk(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
    var count = 0
    for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) where pixel(rep, at: CGPoint(x: x, y: y))[0] < 90 { count += 1 }
    }
    return count
}

@MainActor let paperTests = Suite("A type note's paper", [
    test("a type's note is white, and in the dark 0.92; a plain note is its yellow in both") {
        let (type, _) = try paperEditor(isType: true), (plain, _) = try paperEditor(isType: false)
        expectPaper(pixel(render(type, dark: false), at: paperSpot), [255, 255, 255], "light")
        expectPaper(pixel(render(type, dark: true), at: paperSpot), [235, 235, 235], "dark")
        expectPaper(pixel(render(plain, dark: false), at: paperSpot), yellow, "plain, light")
        expectPaper(pixel(render(plain, dark: true), at: paperSpot), yellow, "plain, dark")
    },
    test("its text is the note's ink on the paper, as on the yellow; its shadow and shape are a plain note's") {
        // A type with words has `No fields` under them, so it reads at 320 wide: both are stored that wide, and
        // the paper is the same frame as the yellow.
        let words = "Where the words are", wide = CGRect(x: 50, y: 50, width: 320, height: 200), canvas = CGSize(width: 420, height: 300)
        let (type, _) = try paperEditor(isType: true, text: words, frame: wide), (plain, _) = try paperEditor(isType: false, text: words, frame: wide)
        let textBox = wide.insetBy(dx: 16, dy: 16).offsetBy(dx: 0, dy: -4).intersection(CGRect(x: 0, y: 0, width: 420, height: 130))
        for dark in [false, true] {
            let onPaper = render(type, dark: dark, size: canvas), onYellow = render(plain, dark: dark, size: canvas)
            expectEqual(darkInk(onPaper, in: textBox) > 20, true, "ink on the paper, dark \(dark)")
            // The darkest pixel is the ink's own.
            var inkPaper = 255, inkYellow = 255
            for y in Int(textBox.minY)..<Int(textBox.maxY) {
                for x in Int(textBox.minX)..<Int(textBox.maxX) {
                    inkPaper = min(inkPaper, pixel(onPaper, at: CGPoint(x: x, y: y))[0])
                    inkYellow = min(inkYellow, pixel(onYellow, at: CGPoint(x: x, y: y))[0])
                }
            }
            expect(abs(inkPaper - inkYellow) <= 6, "the same ink: \(inkPaper), \(inkYellow), dark \(dark)")
            // Outside the note, its shadow and corners: as a plain note's.
            for point in [CGPoint(x: 49, y: 150), CGPoint(x: 150, y: 253), CGPoint(x: 372, y: 150), CGPoint(x: 150, y: 46), CGPoint(x: 46, y: 46)] {
                expectEqual(pixel(onPaper, at: point), pixel(onYellow, at: point), "outside the note at \(point), dark \(dark)")
            }
        }
    },
    test("zoomed out, 30%, a type's note is the paper in each appearance, and a plain note the yellow") {
        let (type, _) = try paperEditor(isType: true, zoom: 0.3), (plain, _) = try paperEditor(isType: false, zoom: 0.3)
        let spot = CGPoint(x: 145 * 0.3 + 10, y: 145 * 0.3 + 25)
        expectPaper(pixel(render(type, dark: false), at: spot), [255, 255, 255], "light")
        expectPaper(pixel(render(type, dark: true), at: spot), [235, 235, 235], "dark")
        expectPaper(pixel(render(plain, dark: false), at: spot), yellow, "plain, light")
        expectPaper(pixel(render(plain, dark: true), at: spot), yellow, "plain, dark")
    },
    test("Remove Type makes it yellow again, and undo white") {
        let (editor, id) = try paperEditor(isType: true)
        expectPaper(pixel(render(editor, dark: false), at: paperSpot), [255, 255, 255], "a type")
        editor.removeType(id)
        expectPaper(pixel(render(editor, dark: false), at: paperSpot), yellow, "removed")
        editor.undo()
        expectPaper(pixel(render(editor, dark: false), at: paperSpot), [255, 255, 255], "and back")
    },
    test("the editing view is over the white: the editor draws no background of its own") {
        let (editor, id) = try paperEditor(isType: true, text: "")
        expect(editor.beginEditing(id))
        let drawn = renderBitmap(editor, size: paperCanvas, editing: try require(editor.makeEditingView()))
        expectPaper(pixel(drawn, at: paperSpot), [255, 255, 255], "white under the editor")
        editor.endEditing()
    },
    test("a titled type's cover reads on the paper in both appearances, a dark ink; a plain note's as it was") {
        let (type, _) = try paperEditor(isType: true, title: "Front desk", zoom: 0.3)
        let note = CGRect(x: 15, y: 15, width: 60, height: 60)
        for dark in [false, true] {
            let drawn = render(type, dark: dark)
            expect(darkInk(drawn, in: note) > 10, "dark ink on the paper, dark \(dark): \(darkInk(drawn, in: note))")
        }
    },
])
