import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Engineering
import Geometry
import TestKit
import Titles

// The looks at rest, light and dark: a table's paper, its rows' marks, types, an enum-typed column's pill and a nullable's
// `?`; an enum's values; a database's region; and zoomed out, bars a row and the titles as bars over the cards. `orders` at
// (100, 100), 260 × 116: rows at 108, 132, 156 and 180, 24 tall; at 100% from the origin, so view points are world units.

/// Whether some pixel of `rect` is as `test` says.
@MainActor func some(_ rep: NSBitmapImageRep, in rect: CGRect, _ test: ([Int]) -> Bool) -> Bool {
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) where test(pixel(rep, at: CGPoint(x: x, y: y))) { return true }
    }
    return false
}

private func gold(_ p: [Int]) -> Bool { p[0] > p[2] + 60 && p[1] > p[2] + 30 }
private func purple(_ p: [Int]) -> Bool { p[0] > p[1] + 20 && p[2] > p[1] + 20 }
private func ink(_ p: [Int]) -> Bool { p[0] < 90 && p[1] < 90 && p[2] < 90 }
private func grey(_ p: [Int]) -> Bool { abs(p[0] - p[2]) < 12 && p[0] > 70 && p[0] < 200 }

@MainActor private func board() throws -> (EditorHarness, ShapeID, ShapeID) {
    let h = try kitHarness()
    let values = h.add(DatabaseEnum(frame: CGRect(x: 400, y: 100, width: 160, height: 68), values: [EnumValue(text: "pending"), EnumValue(text: "paid")]),
                       titled: "order_status")
    let table = h.add(orders(status: values), titled: "orders")
    return (h, table, values)
}

@MainActor let lookTests = Suite("The kit's looks", [
    test("a table: its paper #EBEBEB, a key before a primary key, a 1 before a unique column, types grey at the right, an enum's pill, a nullable's ?") {
        let (h, _, _) = try board()
        for dark in [false, true] {
            let drawn = render(h.editor, dark: dark)
            let mode = dark ? "dark" : "light"
            expectColor(pixel(drawn, at: CGPoint(x: 300, y: 210)), paper, "the paper, \(mode)")
            expect(some(drawn, in: CGRect(x: 110, y: 112, width: 18, height: 16), gold), "the key mark in gold, \(mode)")
            expect(!some(drawn, in: CGRect(x: 110, y: 136, width: 18, height: 16), gold), "no key on customer_id, \(mode)")
            expect(some(drawn, in: CGRect(x: 110, y: 136, width: 18, height: 16), grey), "the unique mark in grey, \(mode)")
            expect(some(drawn, in: CGRect(x: 135, y: 112, width: 20, height: 16), ink), "the name in ink, \(mode)")
            expect(some(drawn, in: CGRect(x: 300, y: 112, width: 46, height: 16), grey), "the type, grey at the right, \(mode)")
            expect(some(drawn, in: CGRect(x: 240, y: 158, width: 106, height: 20), purple), "status's enum in its pill, \(mode)")
            expect(some(drawn, in: CGRect(x: 336, y: 184, width: 10, height: 16), ink), "placed_at's ? in ink at the right end, \(mode)")
            expect(!some(drawn, in: CGRect(x: 336, y: 112, width: 10, height: 16), ink), "no ? after a type that isn't null, \(mode)")
            expect(some(drawn, in: CGRect(x: 435, y: 112, width: 40, height: 16), ink), "an enum's value in ink, \(mode)")
        }
    },
    test("a database: a surface in a hairline border, white on the light canvas and a raised grey on the dark, its name in a tab on its top edge") {
        let h = try kitHarness()
        h.add(Database(frame: CGRect(x: 100, y: 100, width: 400, height: 300)), titled: "shop")
        let light = render(h.editor), dark = render(h.editor, dark: true)
        expectColor(pixel(light, at: CGPoint(x: 300, y: 300)), [255, 255, 255], "its surface")
        expectColor(pixel(dark, at: CGPoint(x: 300, y: 300)), [38, 38, 38], "a step up from the dark canvas")
        expect(some(light, in: CGRect(x: 110, y: 92, width: 60, height: 16)) { $0[0] < 200 }, "its tab's text on the top edge")
        expect(h.editor.titlePillRect(of: try require(h.shapes(Database.kind).first).id) != nil, "a tab, where a pill would be")
    },
    test("an untitled table's pill shows its glyph and a dimmed Table to grab it by; a titled one's, its name") {
        let h = try kitHarness()
        let table = h.add(orders())
        let pill = try require(h.editor.titlePillRect(of: table))
        expectEqual(pill.minX, 100)
        expect(pill.maxY <= 100, "above the paper")
        let drawn = render(h.editor)
        expect(some(drawn, in: pill) { $0[0] < 120 }, "the pill's dark capsule")
    },
    test("zoomed out: the paper, a bar a name and a type, the enum's in its purple, and each title a bar above its card, its enum's in purple") {
        let (h, table, values) = try board()
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expect(h.editor.drawsSkeleton(of: table))
        let drawn = render(h.editor)
        // At 30% the table is 30 to 108 across and 30 to 64.8 down; its title's row 3 to 21 down.
        expectColor(pixel(drawn, at: CGPoint(x: 100, y: 62)), paper, "its paper", within: 6)
        expect(some(drawn, in: CGRect(x: 40, y: 31, width: 20, height: 33)) { $0[0] < 200 }, "its names' bars")
        expect(some(drawn, in: CGRect(x: 70, y: 46, width: 37, height: 8), purple), "its enum's bar, purple")
        expect(some(drawn, in: CGRect(x: 32, y: 6, width: 30, height: 12)) { $0[0] < 120 }, "its title, a bar above it")
        expect(some(drawn, in: CGRect(x: 122, y: 6, width: 30, height: 12), purple), "the enum's title bar, in its purple")
        expectEqual(h.editor.titleCover(of: table), nil, "no cover printed over its rows")
        expectEqual(h.editor.titleCover(of: values), nil)
        let dark = render(h.editor, dark: true)
        expectColor(pixel(dark, at: CGPoint(x: 100, y: 62)), paper, "the paper in the dark too", within: 6)
        expect(some(dark, in: CGRect(x: 32, y: 6, width: 30, height: 12)) { $0[0] > 90 }, "its title bar, lighter on the dark canvas")
    },
])
