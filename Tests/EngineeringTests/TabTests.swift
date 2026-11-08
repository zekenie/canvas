import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Engineering
import Geometry
import TestKit
import Titles

// A table at a database's top-left inset, zoomed out to 30%: the database's tab keeps its size on screen and the inset
// doesn't, so the table's title bar would cover "shop". The row above a shape gives way to its container's tab (Adornments),
// and Titles' bar starts where the row does: clear of the tab, light and dark.

@MainActor let tabTests = Suite("A title clear of its container's tab", [
    test("at 30% a table at a database's top-left draws its title bar past the database's tab, light and dark; at 100% its pill is clear of it too") {
        let h = try kitHarness()
        let shop = h.add(Database(frame: CGRect(x: 100, y: 100, width: 800, height: 500)), titled: "shop")
        let orders = h.add(DatabaseTable(frame: CGRect(x: 132, y: 132, width: 260, height: 0), columns: [ColumnGrammar.read("id uuid pk")!]),
                           titled: "orders")
        h.editor.put([orders], in: shop)
        h.editor.camera = Camera(origin: CGPoint(x: 0, y: 0), zoom: 1)
        _ = render(h.editor, size: CGSize(width: 1000, height: 800))
        let tabAtFull = try require(h.editor.adornmentFrames(of: shop).first { $0.adornment.placement == .onTopEdge }?.rect)
        let pillAtFull = try require(h.editor.adornmentFrames(of: orders).first { $0.adornment.placement == .aboveTopLeft }?.rect)
        expect(!pillAtFull.intersects(tabAtFull), "at 100% the pill is clear of the tab: \(pillAtFull) \(tabAtFull)")
        h.editor.camera = Camera(origin: CGPoint(x: 0, y: 0), zoom: 0.3)
        expect(h.editor.drawsSkeletons)
        for dark in [false, true] {
            let size = CGSize(width: 400, height: 300)
            let bitmap = render(h.editor, size: size, dark: dark)
            let start = h.editor.adornmentRowStart(of: orders)
            expect(start > 0, "the bar gives way: \(start)")
            let tab = try require(h.editor.adornmentFrames(of: shop).first { $0.adornment.placement == .onTopEdge }?.rect, "shop's tab")
            expect(132 + start >= tab.maxX, "the bar starts past the tab's end: \(132 + start) vs \(tab.maxX)")
            // The tab's right end, in view points: its surface, not the bar's fill.
            let point = h.editor.camera.toView(CGPoint(x: tab.maxX - 2 / 0.3, y: tab.midY))
            var pixel = [Int](repeating: 0, count: 4)
            bitmap.getPixel(&pixel, atX: Int(point.x), y: Int(point.y))
            let bar = (dark ? NSColor(white: 0.5, alpha: 1) : NSColor(white: 0.25, alpha: 1)).usingColorSpace(.deviceRGB)!
            let barValue = Int(bar.redComponent * 255)
            expect(abs(pixel[0] - barValue) > 20 || abs(pixel[1] - barValue) > 20, "\(dark ? "dark" : "light"): the tab's end isn't under a bar: \(pixel)")
            // The tab itself was drawn there: its middle is not the canvas.
            var ground = [Int](repeating: 0, count: 4), middle = [Int](repeating: 0, count: 4)
            let inside = h.editor.camera.toView(CGPoint(x: tab.midX, y: tab.midY))
            bitmap.getPixel(&ground, atX: 395, y: 295)
            bitmap.getPixel(&middle, atX: Int(inside.x), y: Int(inside.y))
            expect(zip(ground, middle).prefix(3).contains { abs($0 - $1) > 8 }, "\(dark ? "dark" : "light"): the tab is drawn: \(middle) on \(ground)")
        }
    },
    test("a table's name typed in its pill starts where the pill was, past the database's tab, and the pill didn't move as typing began") {
        let b = try KitBench()
        let shop = b.h.add(Database(frame: CGRect(x: 100, y: 100, width: 800, height: 500)), titled: "shop")
        let orders = b.h.add(DatabaseTable(frame: CGRect(x: 132, y: 132, width: 260, height: 0), columns: [ColumnGrammar.read("id uuid pk")!]), titled: "orders")
        b.editor.put([orders], in: shop)
        b.editor.camera = Camera(origin: .zero, zoom: 1)
        _ = render(b.editor, size: CGSize(width: 1000, height: 800))
        let tab = try require(b.editor.adornmentFrames(of: shop).first { $0.adornment.placement == .onTopEdge }?.rect, "shop's tab")
        let pill = try require(b.editor.adornmentFrames(of: orders).first { $0.adornment.placement == .aboveTopLeft }?.rect, "orders' pill")
        expect(pill.minX >= tab.maxX, "at rest the pill is past the tab")
        b.begin(orders)
        let field = try require(b.canvas.descendants(TitleField.self).first, "the title's field")
        let typed = field.convert(field.bounds, to: b.canvas)
        expect(typed.minX >= tab.maxX - 0.5, "the field starts past the tab: \(typed) vs \(tab)")
        expect(abs(typed.minX - pill.minX) < 1, "where the pill was: \(typed.minX) vs \(pill.minX)")
    },
])
