import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Engineering
import Geometry
import Keyboard
import Palette
import Selection
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
    test("a selected table, enum or API is resized by its corners alone: no handle at a side's middle, where a row's key ends (UX walk 3 tables-3)") {
        let (h, table, values) = try board()
        for id in [table, values] {
            h.editor.selection = id
            var titles: [String] = []
            for _ in 0..<12 {
                h.key(Chord.optionTab)
                if let title = h.editor.focusedPart?.title, !titles.contains(title) { titles.append(title) }
            }
            for corner in ["Top Left Corner", "Top Right Corner", "Bottom Right Corner", "Bottom Left Corner"] {
                expect(titles.contains(corner), "\(corner) among \(titles)")
            }
            for edge in ["Left Edge", "Right Edge", "Top Edge", "Bottom Edge"] { expect(!titles.contains(edge), "no \(edge): \(titles)") }
        }
    },
    test("a table's corners show the side's resize cursor and ⇧ keeps no proportions: its width is all a drag gives it (review U9-E7)") {
        let (h, table, _) = try board()
        h.editor.selection = table
        let frame = try require(h.editor.document[table]?.box)
        h.move(to: CGPoint(x: frame.maxX, y: frame.maxY))
        expectEqual(h.editor.cursor, .resize(.right), "the bottom right corner")
        h.move(to: CGPoint(x: frame.minX, y: frame.minY))
        expectEqual(h.editor.cursor, .resize(.left), "the top left corner")
        h.move(to: CGPoint(x: frame.maxX, y: frame.minY))
        expectEqual(h.editor.cursor, .resize(.right), "the top right corner")
        // ⇧ held through a drag: the width follows the pointer alone, as without it.
        var widths: [CGFloat] = []
        for held in [Modifiers(), .shift] {
            h.editor.undoHistory.seal()
            let corner = CGPoint(x: frame.maxX, y: frame.maxY)
            h.hold(held)
            h.move(to: corner)
            h.press(at: corner)
            h.drag(to: corner + CGPoint(x: 60, y: 90))
            expectEqual(h.editor.cursor, .resize(.right), "dragged")
            h.release()
            h.hold([])
            widths.append(try require(h.editor.document[table]?.box).width)
            h.editor.undo()
        }
        expectClose(widths[0], widths[1], within: 1e-6)
        expect(widths[0] > frame.width, "wider: \(widths[0]) from \(frame.width)")
    },
    test("a database's table with a tab over its top-left keeps its bar over its own table, not past its right edge, or, where too little is left past the tab, at its own top edge with the tab given way up off the database's; far out (UX walk 3 structure-3, review U9-E1, UX walk 5 structure-3)") {
        let h = try kitHarness()
        h.editor.viewportDidResize(to: CGSize(width: 600, height: 400))
        let shop = h.add(Database(frame: CGRect(x: 50, y: 100, width: 900, height: 400)), titled: "shop")
        let column = [Column(name: "id", type: TypeRef("uuid"), primaryKey: true)]
        // 420 wide: past the tab, about 60 of its 126 points are left (more than half the bar, less than all of it); the next 60 over.
        let wide = h.add(DatabaseTable(frame: CGRect(x: 70, y: 160, width: 420, height: 120), columns: column), titled: "orders")
        let beside = h.add(DatabaseTable(frame: CGRect(x: 550, y: 160, width: 300, height: 120), columns: column), titled: "customers")
        h.editor.put([wide, beside], in: shop)
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        @MainActor func view(_ id: ShapeID) throws -> CGRect {
            let frame = try require(h.editor.shapeContext.frame(of: try require(h.editor.document[id])))
            return CGRect(x: frame.minX * 0.3, y: frame.minY * 0.3, width: frame.width * 0.3, height: frame.height * 0.3)
        }
        @MainActor func bar(_ rep: NSBitmapImageRep, _ x: Range<Int>, y: Int) -> Bool {
            some(rep, in: CGRect(x: x.lowerBound, y: y, width: x.count, height: 1)) { $0[0] < 120 }
        }
        let (first, second) = (try view(wide), try view(beside))
        let rep = render(h.editor)
        let above = Int(first.minY) - 5
        expect(bar(rep, Int(first.maxX) - 20..<Int(first.maxX) - 2, y: above), "its bar, over its own table, to its right edge")
        expect(!bar(rep, Int(first.maxX) + 2..<Int(second.minX) - 2, y: above), "none in the gap: it stops at its table's edge, never over the next table's bar")
        expect(bar(rep, Int(second.minX) + 4..<Int(second.minX) + 40, y: above), "the next table's own bar")
        @MainActor func shopTab() throws -> CGRect { try require(h.editor.adornmentFrames(of: shop).first { $0.label.text == "shop" }?.rect, "the database's tab") }
        let onEdge = try shopTab()
        expect(onEdge.minY < 100 && onEdge.maxY > 100, "a bar that starts past the tab leaves it on the database's edge: \(onEdge)")
        // 150 wide (45 points): too little past the tab, so the bar is at its own top edge, from its left, as every other bar is, and
        // the tab gives way, up off the database's edge, clear of it.
        h.editor.transact { $0.update(wide, as: DatabaseTable.self) { $0.props.frame.size.width = 150 } }
        let narrow = render(h.editor)
        let table = try view(wide)
        expect(bar(narrow, Int(table.minX) + 3..<Int(table.minX) + 30, y: Int(table.minY) - 4), "its bar just above its top edge, from its left")
        let lifted = try shopTab()
        // The bar's top: 1.5 points above the table and 40% of the pill's 18 (6.5 for a selected one's, which it clears too).
        expect(lifted.maxY * 0.3 < table.minY - 6.5 - 7.2, "the tab up clear of the bar: \(lifted) over the table at \(table.minY / 0.3)")
        // Selected, its bar starts past the corner handle that sits on the corner (review U12-E9): gray, as the bar is, never the handle's.
        h.editor.selection = wide
        let selected = render(h.editor)
        @MainActor func gray(_ rep: NSBitmapImageRep, _ x: Range<Int>, y: Int) -> Bool {
            some(rep, in: CGRect(x: x.lowerBound, y: y, width: x.count, height: 1)) { $0[0] < 120 && abs($0[0] - $0[2]) < 12 }
        }
        expect(gray(selected, Int(table.minX) + 9..<Int(table.minX) + 30, y: Int(table.minY) - 10), "its bar, past the handle, above its outline")
        h.editor.selection = nil
        // Far out, with the table just below the database's top, the tab's place reaches over the table's top and its bar: the bar
        // stays just above the table's top (where it was inside it, below the tab, it read as a row of the table's, UX walk 5), and
        // the tab is up clear of it.
        let more = (1...5).map { Column(name: "c\($0)", type: TypeRef("text")) }
        h.editor.transact { $0.update(wide, as: DatabaseTable.self) { $0.props.frame.origin.y = 116; $0.props.columns = column + more } }
        h.editor.camera = Camera(origin: .zero, zoom: 0.1)
        let tab = try shopTab()
        let far = render(h.editor)
        let tableFar = try require(h.editor.shapeContext.frame(of: try require(h.editor.document[wide])))
        let shopFar = try require(h.editor.shapeContext.frame(of: try require(h.editor.document[shop])))
        expect(tab.maxY < tableFar.minY - (6.5 + 7.2 * 0.4) / 0.1, "the tab up clear of the bar: \(tab) over \(tableFar)")
        expect(tab.maxY < shopFar.minY, "off the database's edge: \(tab)")
        let barRow = CGRect(x: Int(tableFar.minX * 0.1) + 1, y: Int((tableFar.minY * 0.1).rounded(.down)) - 3, width: 4, height: 2)
        expect(some(far, in: barRow) { $0[0] < 120 }, "its bar just above the table's top: \(barRow)")
        let inside = CGRect(x: Int(tableFar.minX * 0.1) + 1, y: Int((tableFar.minY * 0.1).rounded(.up)) + 1, width: 4, height: 1)
        expect(!some(far, in: inside) { $0[0] < 120 }, "none inside the table's top: \(inside)")
    },
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
    test("the inks and marks pass Palette's floors on the paper and the canvas: the grey types and the key at theirs, the enum's pill text on its wash, its title pill's text on its purple (decided 25)") {
        let paper = KitStyle.paper
        expect(KitStyle.secondaryInk.contrast(with: paper) >= Swatch.textContrast, "the types' grey on the paper: \(KitStyle.secondaryInk.contrast(with: paper))")
        expect(KitStyle.ink.contrast(with: paper) >= Swatch.textContrast)
        expect(KitStyle.keyGold.contrast(with: paper) < Swatch.lineContrast, "the frames' gold alone doesn't pass, which is why the mark is Palette's")
        let onPaper = KitStyle.onPaper(KitStyle.enumPurple)
        expect(onPaper.solid.light.contrast(with: paper) >= Swatch.lineContrast, "the enum's purple made a line color: the pill's edge")
        expect(KitStyle.onPaper(KitStyle.keyGold).solid.light.contrast(with: paper) >= Swatch.lineContrast)
        let wash = onPaper.solid.light.over(paper, alpha: Swatch.washStrength)
        expect(onPaper.ink.light.contrast(with: wash) >= Swatch.textContrast, "the enum pill's text on its wash")
        let title = Swatch(KitStyle.enumPurple)
        expect(title.onSolid.light.contrast(with: title.solid.light) >= Swatch.textContrast, "the enum's title pill, light canvas")
        expect(title.onSolid.dark.contrast(with: title.solid.dark) >= Swatch.textContrast, "the enum's title pill, dark canvas")
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
    test("zoomed far out, where a row is under three points (about 12%), a table is its paper and its title's bar: no bar a row") {
        let (h, _, _) = try board()
        h.editor.camera = Camera(origin: .zero, zoom: 0.06)
        let drawn = render(h.editor)
        // At 6% the table is 6 to 22 across and 6 to 13 down, a row 1.4 points: its inside is the paper's, bars none.
        for y in 8..<11 {
            for x in 8..<20 { expectColor(pixel(drawn, at: CGPoint(x: x, y: y)), paper, "its paper at \(x), \(y)", within: 8) }
        }
        h.editor.camera = Camera(origin: .zero, zoom: 0.1)
        expect(!some(render(h.editor), in: CGRect(x: 12, y: 12, width: 10, height: 6)) { $0[0] < 200 }, "at 10% a row is 2.4 points: the paper alone")
        h.editor.camera = Camera(origin: .zero, zoom: 0.15)
        expect(some(render(h.editor), in: CGRect(x: 18, y: 18, width: 18, height: 12)) { $0[0] < 200 }, "at 15% a row is 3.6 points and has its bars")
    },
    test("zoomed out, a column whose enum is gone has a grey bar as its type, as it has plain words in full: no pill that isn't there at 100%") {
        let (h, table, values) = try board()
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expect(some(render(h.editor), in: CGRect(x: 70, y: 46, width: 37, height: 8), purple), "its enum's bar, purple, while the enum is there")
        h.editor.transact("Delete") { $0.delete([values]) }
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expect(h.editor.drawsSkeleton(of: table))
        let drawn = render(h.editor)
        expect(!some(drawn, in: CGRect(x: 70, y: 46, width: 37, height: 8), purple), "the enum's gone: no purple bar")
        expect(some(drawn, in: CGRect(x: 70, y: 46, width: 37, height: 8)) { $0[0] < 200 }, "its words' bar, as the other types'")
    },
    test("zoomed out: the paper, a bar a name and a type, the enum's in its purple, and each title a bar above its card, its enum's in purple") {
        let (h, table, values) = try board()
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expect(h.editor.drawsSkeleton(of: table))
        let drawn = render(h.editor)
        // At 30% the table is 30 to 108 across and 30 to 64.8 down; its title's bar just above it, 21.3 to 28.5 down.
        expectColor(pixel(drawn, at: CGPoint(x: 100, y: 62)), paper, "its paper", within: 6)
        expect(some(drawn, in: CGRect(x: 40, y: 31, width: 20, height: 33)) { $0[0] < 200 }, "its names' bars")
        expect(some(drawn, in: CGRect(x: 70, y: 46, width: 37, height: 8), purple), "its enum's bar, purple")
        expect(some(drawn, in: CGRect(x: 32, y: 21, width: 30, height: 8)) { $0[0] < 120 }, "its title, a bar above it")
        expect(some(drawn, in: CGRect(x: 122, y: 21, width: 30, height: 8), purple), "the enum's title bar, in its purple")
        expectEqual(h.editor.titleCover(of: table), nil, "no cover printed over its rows")
        expectEqual(h.editor.titleCover(of: values), nil)
        let dark = render(h.editor, dark: true)
        expectColor(pixel(dark, at: CGPoint(x: 100, y: 62)), paper, "the paper in the dark too", within: 6)
        expect(some(dark, in: CGRect(x: 32, y: 21, width: 30, height: 8)) { $0[0] > 90 }, "its title bar, lighter on the dark canvas")
    },
])
