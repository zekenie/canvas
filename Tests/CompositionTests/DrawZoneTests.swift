import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Foundation
import Geometry
import StickyNotes
import TestKit
import Titles

// Zones, end to end: `canvas draw` as built, against the app's command server, on boards in a
// 1440 × 900 window, whose view is (0, 0) to (1440, 900) until a test moves the camera. A board shape
// isn't in the way of a shape placed on it, but is its zone, when it wholly holds the shape where
// it already sat, a shape it's placed against (at twice that one's area), where it lands and other
// shapes too (at twice its area), or the view it's placed against or drawn in; a shape the same
// script places is one it holds only when it's on it for a reason of its own. Whatever else it
// lands on is in the way: it's pushed past, and said to be, or it's `no_room` or `unordered`.

/// What a `canvas draw` came to: its rows and warnings, or its error.
private struct Drew {
    var status: Int32
    var rows: [JSON] = []
    var warnings: [String] = []
    var error: JSON?

    func row(_ title: String) -> JSON? { rows.first { $0["title"]?.stringValue == title } }
    /// Where a shape went.
    func at(_ title: String) -> CGRect? { row(title).flatMap { Drew.rect($0["at"]) } }
    /// What a shape was pushed past, by name.
    func pushed(_ title: String) -> [String] { row(title)?["pushedPast"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    var reason: String? { error?["error"]?["reason"]?.stringValue }
    var message: String? { error?["error"]?["message"]?.stringValue }
    var hint: String? { error?["error"]?["hint"]?.stringValue }

    static func rect(_ json: JSON?) -> CGRect? {
        guard let pair = json?.arrayValue, pair.count == 2, let origin = pair[0].arrayValue, let size = pair[1].arrayValue,
              origin.count == 2, size.count == 2, let x = origin[0].numberValue, let y = origin[1].numberValue,
              let width = size[0].numberValue, let height = size[1].numberValue else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A board as the app makes one, in a window, with the app's command server to draw on it through.
@MainActor
private final class ZoneBoard {
    let board: BoardDocument
    let server: CommandServer

    init() throws {
        try configureBoards()
        board = windowedBoard()
        server = try startCommandServer(boards: [board], frontmost: board)
    }

    /// The server stops, and the board closes.
    func stop() {
        server.stop()
        board.close()
    }

    /// `canvas draw`, as a dry run if asked, and what it said.
    func draw(_ script: String, dryRun: Bool = false) throws -> Drew {
        let result = try CompositionTests.draw(script, on: board, server, dryRun ? ["--dry-run"] : [])
        guard result.status == 0 else { return Drew(status: result.status, error: try? JSON(text: result.error)) }
        let json = try JSON(text: result.output)
        return Drew(status: 0, rows: json["changes"]?.arrayValue ?? [],
                    warnings: json["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue } ?? [])
    }

    /// Draws for real what a test starts from, which must draw.
    @discardableResult
    func start(_ script: String) throws -> Drew {
        let drew = try draw(script)
        expectEqual(drew.status, 0, "\(script): \(drew.error ?? .null)")
        return drew
    }

    /// The part of the board in the window.
    var view: CGRect { board.editor.cameraTarget.toWorld(CGRect(origin: .zero, size: board.editor.viewportSize)) }

    /// Moves the camera, so the view's top-left is at `origin`.
    func look(from origin: CGPoint, zoom: CGFloat = 1) {
        board.editor.camera = Camera(origin: origin, zoom: zoom)
    }

    /// The board's shapes with frames, by title, in paint order.
    var shapes: [(title: String, box: CGRect)] {
        board.editor.document.shapes.compactMap { record in record.box.map { (record[TitleProperty.self] ?? "", $0) } }
    }

    func box(_ title: String) throws -> CGRect { try require(shapes.first { $0.title == title }?.box, "\"\(title)\" is on the board") }

    /// Where a shape paints: its place in the stack.
    func paints(_ title: String) throws -> Int { try require(board.editor.document.shapes.firstIndex { $0[TitleProperty.self] == title }) }

    /// Each pair of shapes that overlap, but a zone and a shape it wholly holds that `held` names
    /// (zone first).
    func overlaps(besides held: Set<[String]> = []) -> [String] {
        let shapes = self.shapes
        var found: [String] = []
        for (at, a) in shapes.enumerated() {
            for b in shapes[(at + 1)...] {
                let overlap = a.box.intersection(b.box)
                guard !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 else { continue }
                if a.box.contains(b.box), held.contains([a.title, b.title]) { continue }
                if b.box.contains(a.box), held.contains([b.title, a.title]) { continue }
                found.append("\"\(a.title)\" and \"\(b.title)\"")
            }
        }
        return found
    }
}

/// `"P" was pushed right past "B" …`, as a push's warning says it.
private func pushedRight(_ title: String, past: String, from: String) -> String {
    "\"\(title)\" was pushed right past \"\(past)\" to keep clear of it, so it no longer sits against \"\(from)\" — place it on another side, or say overlap: allow"
}

/// A shape `size` in a corner of `region`, 40 in, as `inside … <corner>` puts it.
private func corner(_ corner: String, of region: CGRect, _ size: CGSize) -> CGRect {
    let x = corner.hasSuffix("left") ? region.minX + 40 : region.maxX - 40 - size.width
    let y = corner.hasPrefix("top") ? region.minY + 40 : region.maxY - 40 - size.height
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
}

/// A note drawn at its own size is a new note's, `noteSize`. A card is a subboard drawn `size: 240x200`, `cardSize`;
/// one drawn at its own size is `subboardSize`. A small note is a note drawn `size: 160x100`, `smallSize`, as the frames
/// and boxes of these tests are.
private let noteSize = StickyNote.defaultSize, cardSize = CGSize(width: 240, height: 200)
private let smallSize = CGSize(width: 160, height: 100), subboardSize = CGSize(width: 240, height: 160)
/// A square note, drawn `size: 200x200`: wholly on an empty frame, it's pushed off sideways, where a new note,
/// wider than tall, is pushed the way it overlaps less, across the frame's top or bottom, as a subboard is.
private let squareSize = CGSize(width: 200, height: 200)
private let corners = ["top-left", "top-right", "bottom-left", "bottom-right"]

@MainActor let drawZoneTests = Suite("canvas draw's zones", [
    test("a shape that lands on the next note or card is pushed past it, and says so, whatever its kind: they hold nothing else") {
        let notes = try ZoneBoard()
        defer { notes.stop() }
        try notes.start(#"""
            sticky-note "A" text: "a"
            sticky-note "B" right of "A" text: "b"
            """#)
        let a = try notes.box("A"), b = try notes.box("B")
        for (kind, size) in [("subboard", subboardSize), ("sticky-note", noteSize)] {
            let at = CGRect(x: b.maxX + 40, y: a.midY - size.height / 2, width: size.width, height: size.height)
            let p = try notes.draw("\(kind) \"P\" right of \"A\"", dryRun: true)
            expectEqual(p.at("P"), at, kind)
            expectEqual(p.pushed("P"), ["B"], kind)
            expectEqual(p.warnings, [pushedRight("P", past: "B", from: "A")], kind)
        }
        let cards = try ZoneBoard()
        defer { cards.stop() }
        try cards.start(#"""
            sticky-note "A2" text: "a"
            subboard "C2" right of "A2" size: 240x200
            """#)
        for kind in ["subboard", "sticky-note"] {
            let p = try cards.draw("\(kind) \"P\" right of \"A2\"", dryRun: true)
            expectEqual(p.at("P")?.minX, try cards.box("C2").maxX + 40, kind)
            expectEqual(p.pushed("P"), ["C2"], kind)
            expectEqual(p.warnings, [pushedRight("P", past: "C2", from: "A2")], kind)
        }
        // Three cards in a row: a note right of the first, then a subboard of its own size right of
        // the second.
        let row = try ZoneBoard()
        defer { row.stop() }
        try row.start(#"""
            subboard "A" size: 240x200
            subboard "B" right of "A" size: 240x200
            subboard "C" right of "B" size: 240x200
            """#)
        let note = try row.start(#"sticky-note "Note on A" right of "A" text: "should not land on B""#)
        expectEqual(note.at("Note on A"), CGRect(origin: CGPoint(x: 1200, y: 350), size: noteSize))
        expectEqual(note.pushed("Note on A"), ["B", "C"])
        let subboard = try row.start(#"subboard "E" right of "B""#)
        expectEqual(subboard.at("E"), CGRect(x: try row.box("Note on A").maxX + 40, y: 370, width: 240, height: 160))
        expectEqual(subboard.pushed("E"), ["C", "Note on A"])
        expectEqual(row.overlaps(), [])
        // The same neighbors in a frame: the frame holds them, and is a zone; the next note is in the way.
        let framed = try ZoneBoard()
        defer { framed.stop() }
        try framed.start(#"sticky-note "Frame" size: 1300x700"#)
        try framed.start(#"""
            sticky-note "A" inside "Frame" left text: "a"
            sticky-note "B" right of "A" text: "b"
            """#)
        for kind in ["subboard", "sticky-note"] {
            let p = try framed.draw("\(kind) \"P\" right of \"A\"", dryRun: true)
            expectEqual(p.pushed("P"), ["B"], kind)
            expectEqual(p.warnings, [pushedRight("P", past: "B", from: "A")], kind)
        }
    },
    test("the skill's zone: notes in a row in a zone below the board sit on it, above it, and the one over its edge is said") {
        let b = try ZoneBoard()
        defer { b.stop() }
        let empty = try b.draw(#"sticky-note "Backend" below board size: 900x320"#, dryRun: true)
        expectEqual(empty.reason, "unknown_title")
        expectEqual(empty.message, #""Backend" is below board, and the board has nothing on it yet"#)
        try b.start(#"""
            sticky-note "Web" text: "Browser app"
            sticky-note "API" right of "Web" text: "Public HTTP API"
            sticky-note "DB" right of "API" text: "Postgres"
            """#)
        let zone = try b.start(#"sticky-note "Backend" below board size: 900x320"#)
        let backend = try require(zone.at("Backend"))
        expectEqual(backend, CGRect(x: 270, y: 630, width: 900, height: 320))
        let inside = try b.start(#"""
            sticky-note "Queue" inside "Backend" top-left text: "Jobs waiting to run"
            sticky-note "Worker" right of "Queue" text: "Runs each job"
            sticky-note "Retry" right of "Worker" text: "Retries failed jobs"
            sticky-note "Dead letters" right of "Retry" text: "Jobs that gave up"
            edge "Queue" -> "Worker"
            """#)
        for (step, title) in ["Queue", "Worker", "Retry", "Dead letters"].enumerated() {
            let x = backend.minX + 40 + (noteSize.width + 80) * CGFloat(step)
            expectEqual(inside.at(title), CGRect(origin: CGPoint(x: x, y: backend.minY + 40), size: noteSize), title)
            expectEqual(inside.pushed(title), [], title)
            expect(try b.paints(title) > b.paints("Backend"), "\(title) paints above Backend")
        }
        expectEqual(inside.warnings.filter { !$0.contains("outside the view") },
                    [#""Retry" hangs over the edge of "Backend" — make "Backend" bigger, or place "Retry" elsewhere"#])
        expectEqual(b.overlaps(besides: [["Backend", "Queue"], ["Backend", "Worker"]]), [#""Backend" and "Retry""#])
        // Beside the last, past the zone's edge, a card lands clear of it; below one in it, a
        // note sits on it, over its edge.
        let more = try b.draw(#"""
            subboard "Scheduler" right of "Dead letters" size: 240x200
            sticky-note "Metrics" below "Worker" (gap: tight) size: 160x100
            """#, dryRun: true)
        let worker = try b.box("Worker"), dead = try b.box("Dead letters")
        expectEqual(more.at("Scheduler"), CGRect(x: dead.maxX + 80, y: 670, width: 240, height: 200))
        expectEqual(more.at("Metrics"), CGRect(x: worker.midX - 80, y: worker.maxY + 40, width: 160, height: 100))
        expectEqual(more.pushed("Scheduler") + more.pushed("Metrics"), [])
        expectEqual(more.warnings.filter { !$0.contains("outside the view") },
                    [#""Metrics" hangs over the edge of "Backend" — make "Backend" bigger, or place "Metrics" elsewhere"#])
    },
    test("zoomed into a frame that holds the whole view, a legend inside the view's corners lands in them, at any zoom") {
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"sticky-note "Frame" size: 5000x4000"#)
        let frame = try b.box("Frame")
        b.look(from: CGPoint(x: frame.minX + 1500, y: frame.minY + 1200))
        let view = b.view
        expect(frame.contains(view), "the view is in the frame")
        for (kind, size) in [("sticky-note", noteSize), ("subboard", subboardSize)] {
            for place in ["top-right", "top-left"] {
                let legend = try b.draw("\(kind) \"Legend\" inside view \(place)", dryRun: true)
                expectEqual(legend.at("Legend"), corner(place, of: view, size), "\(kind) \(place)")
                expectEqual(legend.pushed("Legend"), [], "\(kind) \(place)")
                expectEqual(legend.warnings, [], "\(kind) \(place)")
            }
        }
        // For real, both corners, and a swatch below one: all above the frame.
        let both = try b.start(#"""
            sticky-note "Legend" inside view top-right text: "Legend"
            sticky-note "Key" inside view top-left text: "Key"
            sticky-note "Swatch" below "Legend" (gap: tight) size: 160x100
            """#)
        expectEqual(both.warnings, [])
        expect(try b.paints("Legend") > b.paints("Frame"), "the legend paints above the frame")
        for zoom in [2.0, 0.5] {
            b.look(from: CGPoint(x: frame.minX + 200, y: frame.minY + 200), zoom: zoom)
            let legend = try b.draw(#"subboard "Legend 2" inside view top-right"#, dryRun: true)
            expectEqual(legend.at("Legend 2"), corner("top-right", of: b.view, subboardSize), "zoom \(zoom)")
            expectEqual(legend.pushed("Legend 2"), [], "zoom \(zoom)")
        }
    },
    test("with a sliver of canvas beside a frame, a legend lands in any corner of the view on the frame while it holds other shapes; empty, it's in the way") {
        for holds in [true, false] {
            let b = try ZoneBoard()
            defer { b.stop() }
            try b.start(#"sticky-note "Frame" size: 4000x3000"#)
            if holds { try b.start(#"sticky-note "Contents" inside "Frame" bottom-right text: "far from the view""#) }
            let frame = try b.box("Frame")
            for (beside, origin) in [("left of", CGPoint(x: frame.minX - 10, y: frame.minY + 500)),
                                     ("above", CGPoint(x: frame.minX + 500, y: frame.minY - 10)),
                                     ("right of", CGPoint(x: frame.maxX - 1430, y: frame.minY + 500))] {
                b.look(from: origin)
                let view = b.view
                expect(!frame.contains(view) && frame.intersection(view).width >= 1430 && frame.intersection(view).height >= 890, "10 of canvas \(beside) the frame")
                for place in corners {
                    let legend = try b.draw("sticky-note \"Legend\" inside view \(place)", dryRun: true)
                    let what = "\(place), canvas \(beside) the frame, \(holds ? "holding" : "empty")"
                    if holds {
                        expectEqual(legend.at("Legend"), corner(place, of: view, noteSize), what)
                        expectEqual(legend.pushed("Legend"), [], what)
                        expectEqual(legend.warnings, [], what)
                    } else {
                        expectEqual(legend.reason, "no_room", what)
                        expectEqual(legend.message, "\"Legend\" is inside view \(place), and there's no room left in view clear of \"Frame\"", what)
                    }
                }
            }
            if !holds {
                // Said to overlap, it goes in the corner anyway.
                b.look(from: CGPoint(x: frame.minX - 10, y: frame.minY + 500))
                let allowed = try b.draw(#"sticky-note "Legend" inside view top-right overlap: allow"#, dryRun: true)
                expectEqual(allowed.at("Legend"), corner("top-right", of: b.view, noteSize))
            }
            // Zoomed out, 40 of canvas showing on the left.
            b.look(from: CGPoint(x: frame.minX - 40, y: frame.minY + 200), zoom: 0.5)
            let out = try b.draw(#"subboard "Legend" inside view top-right"#, dryRun: true)
            if holds {
                expectEqual(out.at("Legend"), corner("top-right", of: b.view, subboardSize))
            } else {
                expectEqual(out.reason, "no_room")
            }
        }
    },
    test("the frame's edge a third of the way across the view: a legend in the corner on it lands there while the frame holds other shapes; empty, it's pushed off it") {
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"sticky-note "Frame" size: 3000x2000"#)
        let frame = try b.box("Frame")
        b.look(from: CGPoint(x: frame.minX - 480, y: frame.minY + 300))
        let view = b.view
        let empty = try b.draw(#"sticky-note "Legend" inside view top-right size: 200x200"#, dryRun: true)
        expectEqual(empty.at("Legend"), CGRect(origin: CGPoint(x: frame.minX - 40 - 200, y: view.minY + 40), size: squareSize))
        expectEqual(empty.pushed("Legend"), ["Frame"])
        expectEqual(empty.warnings, [#""Legend" was pushed left past "Frame" to keep clear of it, so it no longer sits against view top-right — place it on another side, or say overlap: allow"#])
        try b.start(#"sticky-note "Contents" inside "Frame" bottom-right text: "far from the view""#)
        let legend = try b.draw(#"sticky-note "Legend" inside view top-right"#, dryRun: true)
        expectEqual(legend.at("Legend"), corner("top-right", of: view, noteSize))
        expectEqual(legend.pushed("Legend"), [])
        expectEqual(legend.warnings, [])
        let key = try b.draw(#"sticky-note "Key" inside view top-left"#, dryRun: true)
        expectEqual(key.at("Key"), corner("top-left", of: view, noteSize), "on the canvas beside the frame")
        // Over the frame's edge, it isn't on the frame, which is in its way.
        let wide = try b.draw(#"sticky-note "Wide" inside view bottom-left size: 600x100"#, dryRun: true)
        expectEqual(wide.reason, "no_room")
        expectEqual(wide.message, #""Wide" is inside view bottom-left, and there's no room left in view clear of "Frame""#)
    },
    test("a frame with a note sticking out of it: inside board's corners on the frame land there while it holds other shapes; empty, it's in the way") {
        for holds in [true, false] {
            let b = try ZoneBoard()
            defer { b.stop() }
            try b.start(#"sticky-note "Frame" size: 2000x1200"#)
            if holds { try b.start(#"sticky-note "Contents" inside "Frame" bottom-center text: "c""#) }
            try b.start(#"sticky-note "Corner" on "Frame" bottom-right text: "sticking out""#)
            let frame = try b.box("Frame")
            // Its top-left corner is the frame's: on it, while the frame holds other shapes. The
            // others are out past the frame's edge, where the note sticks out, so the frame is in
            // the way of a legend there, and the board has no room clear of it.
            for place in ["top-left", "top-right", "bottom-left"] {
                let legend = try b.draw("sticky-note \"Legend\" inside board \(place)", dryRun: true)
                let what = "\(place), \(holds ? "holding" : "empty")"
                if holds && place == "top-left" {
                    expectEqual(legend.at("Legend"), corner("top-left", of: frame, noteSize), what)
                    expectEqual(legend.pushed("Legend"), [], what)
                    expectEqual(legend.warnings.filter { !$0.contains("outside the view") }, [], what)
                } else {
                    expectEqual(legend.reason, "no_room", what)
                    expectEqual(legend.message, "\"Legend\" is inside board \(place), and there's no room left in board clear of \"Frame\"", what)
                }
            }
        }
        // A note beside the frame instead: the board's top-right corner is on the frame, and a
        // legend lands there while the frame holds other shapes; empty, it's pushed off the frame.
        for holds in [true, false] {
            let b = try ZoneBoard()
            defer { b.stop() }
            try b.start(#"sticky-note "Frame" size: 2000x1200"#)
            if holds { try b.start(#"sticky-note "Contents" inside "Frame" bottom-center text: "c""#) }
            try b.start(#"sticky-note "Stray" left of "Frame" text: "s""#)
            let frame = try b.box("Frame")
            let legend = try b.draw(#"sticky-note "Legend" inside board top-right size: 200x200"#, dryRun: true)
            if holds {
                expectEqual(legend.at("Legend"), corner("top-right", of: frame, squareSize))
                expectEqual(legend.pushed("Legend"), [])
            } else {
                expectEqual(legend.at("Legend"), CGRect(origin: CGPoint(x: frame.minX - 40 - 200, y: frame.minY + 40), size: squareSize))
                expectEqual(legend.pushed("Legend"), ["Frame"])
            }
        }
    },
    test("on a board of one shape, inside board over it is no_room: it holds nothing else, so it's in the way, never drawn over") {
        // What fits on the one shape is kept clear of it; what doesn't fit the board has no room at all.
        let cases: [(only: String, legend: String, fits: Bool)] = [
            (#"subboard "Only" size: 240x200"#, #"sticky-note "Legend" inside board top-right size: 160x100"#, true),
            (#"subboard "Only" size: 240x200"#, #"subboard "Legend" inside board top-right"#, false),
            (#"sticky-note "Only" text: "the user's one note""#, #"sticky-note "Legend" inside board top-right size: 120x120"#, true),
            (#"sticky-note "Only" text: "the user's one note""#, #"sticky-note "Legend" inside board top-right"#, false),
        ]
        for (only, script, fits) in cases {
            let b = try ZoneBoard()
            defer { b.stop() }
            try b.start(only)
            let legend = try b.draw(script, dryRun: true)
            expectEqual(legend.reason, "no_room", "\(only): \(script)")
            expectEqual(legend.message, #""Legend" is inside board top-right, and there's no room left in board"# + (fits ? #" clear of "Only""# : ""),
                        "\(only): \(script)")
        }
        // Framing the board and nothing else, a frame is the same.
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"sticky-note "Frame" size: 2000x1200"#)
        expectEqual(try b.draw(#"sticky-note "Legend" inside board top-right"#, dryRun: true).reason, "no_room")
    },
    test("swimlanes: a card restated in its column moves within it, above it; lined up across, it lands in the next; onto that one's edge, it's pushed past") {
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"""
            sticky-note "Todo" size: 320x1100
            sticky-note "Done" right of "Todo" (gap: 40) size: 320x1100
            """#)
        let cards = try b.start(#"""
            subboard "T1" inside "Todo" top-center size: 240x200
            subboard "T2" below "T1" (gap: 400) size: 240x200
            subboard "T5" inside "Done" top-center size: 240x200
            subboard "T6" below "T5" (gap: 150) size: 240x200
            """#)
        let t2 = try require(cards.at("T2")), t6 = try require(cards.at("T6")), todo = try b.box("Todo"), done = try b.box("Done")
        for (script, y) in [(#"subboard "T2" level with "T6""#, t6.minY), (#"subboard "T2" top level with "T6""#, t6.minY),
                            (#"subboard "T2" bottom level with "T6""#, t6.minY), (#"subboard "T2" level with "T6" top"#, t6.minY - 100)] {
            let restated = try b.draw(script, dryRun: true)
            expectEqual(restated.at("T2"), CGRect(x: t2.minX, y: y, width: 240, height: 200), script)
            expectEqual(restated.pushed("T2"), [], script)
            expectEqual(restated.warnings, [], script)
        }
        // Restated with a new card below it, in one script.
        let both = try b.draw(#"""
            subboard "T2" level with "T6"
            subboard "T3" below "T2" size: 240x200
            """#, dryRun: true)
        expectEqual(both.status, 0)
        expectEqual(both.pushed("T2") + both.pushed("T3"), [])
        // Lined up with the next column's edge, or with a card in it, it lands in that column, among its cards.
        let across = try b.draw(#"subboard "T2" left level with "Done""#, dryRun: true)
        expectEqual(across.at("T2"), CGRect(x: done.minX, y: t2.minY, width: 240, height: 200))
        expectEqual(across.pushed("T2"), [])
        expectEqual(across.warnings, [])
        let withCard = try b.draw(#"subboard "T2" left level with "T6""#, dryRun: true)
        expectEqual(withCard.at("T2"), CGRect(x: t6.minX, y: t2.minY, width: 240, height: 200))
        expectEqual(withCard.pushed("T2"), [])
        expectEqual(withCard.warnings, [])
        // Beside the card in its column, it lands on the next column's edge, which it's pushed past.
        let onto = try b.draw(#"subboard "T2" right of "T1" (gap: 40)"#, dryRun: true)
        expectEqual(onto.at("T2"), CGRect(x: done.maxX + 40, y: -60, width: 240, height: 200))
        expectEqual(onto.pushed("T2"), ["Done"])
        expectEqual(onto.warnings, [pushedRight("T2", past: "Done", from: "T1")])
        // For real: moved in its column, it's still in it, and nothing overlaps but columns and their cards.
        let moved = try b.start(#"subboard "T2" top level with "T6""#)
        expectEqual(moved.row("T2")?["did"], "moved")
        expect(todo.contains(try b.box("T2")), "T2 is in Todo")
        expectEqual(b.overlaps(besides: [["Todo", "T1"], ["Todo", "T2"], ["Done", "T5"], ["Done", "T6"]]), [])
        expectEqual(try b.draw(#"subboard "T1" level with "T5""#, dryRun: true).row("T1")?["did"], "unchanged")
        // Onto the card in its own column: held both ways, it's unordered.
        let clash = try b.draw(#"subboard "T2" level with "T5""#, dryRun: true)
        expectEqual(clash.reason, "unordered")
        expectEqual(clash.message, #""T2" is level with "T5" and can't move, but it overlaps "T1""#)
        // A column drawn over a card, then the card restated in it: it comes up above the column.
        try b.start(#"subboard "Early" right of "Done" (gap: 400) size: 240x200"#)
        try b.start(#"sticky-note "Later" on "Early" size: 320x1100"#)
        expect(try b.paints("Early") < b.paints("Later"), "the card is under its column")
        let raised = try b.start(#"subboard "Early" level with "T6""#)
        expectEqual(raised.warnings.filter { !$0.contains("outside the view") }, [])
        expect(try b.paints("Early") > b.paints("Later"), "raised above its column")
    },
    test("a slot less than twice a card's area, with the card in it: restated where it is, or up to the slot's top, the card stays in it") {
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"sticky-note "Slot" size: 300x260"#)
        try b.start(#"subboard "S1" on "Slot" size: 240x200"#)
        try b.start(#"subboard "R" right of "Slot" (gap: wide) size: 240x200"#)
        let slot = try b.box("Slot"), s1 = try b.box("S1")
        let still = try b.draw(#"subboard "S1" level with "R""#, dryRun: true)
        expectEqual(still.row("S1")?["did"], "unchanged")
        expectEqual(still.warnings, [])
        let up = try b.draw(#"subboard "S1" top level with "Slot""#, dryRun: true)
        expectEqual(up.row("S1")?["did"], "moved")
        expectEqual(up.at("S1"), CGRect(x: s1.minX, y: slot.minY, width: 240, height: 200))
        expectEqual(up.warnings, [])
    },
    test("on a board framed by a region with shapes in it, right of board goes beside it, and inside board's corners on it") {
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"sticky-note "Frame" size: 2000x1200"#)
        try b.start(#"""
            sticky-note "In 1" inside "Frame" top-left text: "1"
            subboard "In 2" right of "In 1" size: 240x200
            """#)
        let frame = try b.box("Frame")
        let side = try b.draw(#"subboard "Side" right of board size: 240x200"#, dryRun: true)
        expectEqual(side.at("Side"), CGRect(x: frame.maxX + 80, y: frame.midY - 100, width: 240, height: 200))
        expectEqual(side.pushed("Side"), [])
        let list = try b.draw(#"""
            subboard "L1" right of board size: 240x200
            subboard "L2" right of board size: 240x200
            subboard "L3" right of board size: 240x200
            """#, dryRun: true)
        expectEqual(list.status, 0)
        expectEqual(list.pushed("L1") + list.pushed("L2") + list.pushed("L3"), [])
        let legend = try b.start(#"sticky-note "Legend" inside board top-right text: "legend""#)
        expectEqual(legend.at("Legend"), corner("top-right", of: frame, noteSize))
        expectEqual(legend.pushed("Legend"), [])
        expectEqual(legend.warnings.filter { !$0.contains("view") }, [])
        let foot = try b.draw(#"sticky-note "Foot" inside board bottom-left size: 160x100"#, dryRun: true)
        expectEqual(foot.at("Foot"), corner("bottom-left", of: frame, smallSize))
        expectEqual(foot.pushed("Foot"), [])
        // In 1 is in the top-left corner, so a key there goes past it.
        let crowded = try b.draw(#"sticky-note "Key" inside board top-left size: 160x100"#, dryRun: true)
        expectEqual(crowded.at("Key"), CGRect(x: frame.minX + 40, y: try b.box("In 1").maxY + 64, width: 160, height: 100))
        expectEqual(crowded.pushed("Key"), ["In 1"])
        let under = try b.draw(#"sticky-note "Under" below board size: 900x320"#, dryRun: true)
        expectEqual(under.pushed("Under"), [])
        expectEqual(b.overlaps(besides: [["Frame", "In 1"], ["Frame", "In 2"], ["Frame", "Legend"]]), [])
    },
    test("a sticker on a note, restated beside the note's neighbor, stays on the note; a shape moved there from elsewhere is pushed past it") {
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"""
            sticky-note "A" text: "a"
            sticky-note "B" right of "A" text: "b"
            sticky-note "Loose" below "A" (gap: wide) size: 160x100
            """#)
        let a = try b.box("A"), note = try b.box("B")
        let loose = try b.draw(#"sticky-note "Loose" right of "A" size: 160x100"#, dryRun: true)
        expectEqual(loose.at("Loose"), CGRect(x: note.maxX + 40, y: a.midY - 50, width: 160, height: 100))
        expectEqual(loose.pushed("Loose"), ["B"])
        try b.start(#"sticky-note "Sticker" on "B" size: 160x100"#)
        let sticker = try b.draw(#"sticky-note "Sticker" right of "A" size: 160x100"#, dryRun: true)
        expectEqual(sticker.at("Sticker"), CGRect(x: note.minX, y: a.midY - 50, width: 160, height: 100))
        expectEqual(sticker.pushed("Sticker"), [])
        expectEqual(sticker.warnings, [])
    },
    test("a note that holds a badge of its own is a zone for a smaller shape landing wholly on it; the badge is in its way, and so is the note once it's pushed half off") {
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"""
            sticky-note "A" text: "a"
            sticky-note "B" right of "A" text: "the user's words"
            """#)
        let a = try b.box("A"), note = try b.box("B")
        // Empty, the note is in the way.
        let alone = try b.draw(#"sticky-note "Small" right of "A" size: 100x60"#, dryRun: true)
        expectEqual(alone.at("Small"), CGRect(x: note.maxX + 40, y: a.midY - 30, width: 100, height: 60))
        expectEqual(alone.pushed("Small"), ["B"])
        try b.start(#"sticky-note "Badge" inside "B" top-left size: 20x20"#)
        let badge = try b.box("Badge")
        expectEqual(badge, CGRect(x: note.minX + 40, y: note.minY + 40, width: 20, height: 20))
        // Clear of the badge, it sits on the note, over its text, above it, and nothing is said.
        let small = try b.start(#"sticky-note "Small" right of "A" size: 100x60"#)
        expectEqual(small.at("Small"), CGRect(x: note.minX, y: a.midY - 30, width: 100, height: 60))
        expectEqual(small.pushed("Small"), [])
        expectEqual(small.warnings, [])
        expect(try b.paints("Small") > b.paints("B"), "it paints above the note")
        // On the badge, it's pushed past it: still wholly on the note, it stays there...
        let over = try b.draw(#"sticky-note "Over" right of "A" top level with "B" size: 60x60"#, dryRun: true)
        expectEqual(over.at("Over"), CGRect(x: badge.maxX + 40, y: note.minY, width: 60, height: 60))
        expectEqual(over.pushed("Over"), ["Badge"])
        expect(note.contains(try require(over.at("Over"))), "on the note")
        // ...and half off it, the note is in its way too.
        let wide = try b.draw(#"sticky-note "Wide" right of "A" top level with "B" size: 180x60"#, dryRun: true)
        expect(badge.maxX + 40 + 180 > note.maxX, "it would hang off the note")
        expectEqual(wide.at("Wide"), CGRect(x: note.maxX + 40, y: note.minY, width: 180, height: 60))
        expectEqual(wide.pushed("Wide"), ["Badge", "B"])
    },
    test("two new shapes can't put each other on an empty note, card, frame or lane: each is on one only for a reason of its own") {
        // A small note and its caption, where the next note is.
        let notes = try ZoneBoard()
        defer { notes.stop() }
        try notes.start(#"""
            sticky-note "A" text: "a"
            sticky-note "N" right of "A" text: "the user's words"
            """#)
        let n = try notes.box("N")
        for script in [#"sticky-note "R" right of "A" size: 160x100"#, "sticky-note \"R\" right of \"A\" size: 160x100\nsticky-note \"Caption\" below \"R\" (gap: none) size: 160x50"] {
            let drew = try notes.draw(script, dryRun: true)
            expectEqual(drew.at("R"), CGRect(x: n.maxX + 40, y: n.midY - 50, width: 160, height: 100), script)
            expectEqual(drew.pushed("R"), ["N"], script)
        }
        let captioned = try notes.draw("sticky-note \"R\" right of \"A\" size: 160x100\nsticky-note \"Caption\" below \"R\" (gap: none) size: 160x50", dryRun: true)
        expectEqual(captioned.at("Caption"), CGRect(x: n.maxX + 40, y: n.midY + 50, width: 160, height: 50))
        expectEqual(captioned.pushed("Caption"), [])
        expectEqual(captioned.warnings.filter { $0.contains("Caption") },
                    [#""Caption" moved right along with "R", which was pushed past "N" to keep clear of it — place "R" on another side, or give "R" overlap: allow"#])
        // Two small notes, the second right of the first, where the next card is.
        let cards = try ZoneBoard()
        defer { cards.stop() }
        try cards.start(#"""
            sticky-note "A" text: "a"
            subboard "C" right of "A" size: 240x200
            """#)
        let c = try cards.box("C")
        let small = try cards.draw(#"""
            sticky-note "L1" right of "A" size: 60x40
            sticky-note "L2" right of "L1" (gap: none) size: 60x40
            """#, dryRun: true)
        expectEqual(small.at("L1"), CGRect(x: c.maxX + 40, y: c.midY - 20, width: 60, height: 40))
        expectEqual(small.at("L2"), CGRect(x: c.maxX + 100, y: c.midY - 20, width: 60, height: 40))
        expectEqual(small.pushed("L1"), ["C"])
        // Placed against neither the note nor each other, two shapes landing on it together.
        let board = try ZoneBoard()
        defer { board.stop() }
        try board.start(#"""
            sticky-note "S1" text: "S1 text"
            sticky-note "S2" right of "S1" top level with "S1" size: 160x100
            sticky-note "S3" below "S1" size: 160x100
            """#)
        let s1 = try board.box("S1"), s2 = try board.box("S2"), s3 = try board.box("S3")
        let above = CGRect(x: s3.midX - 70, y: s1.minY - 64 - 100, width: 140, height: 100)
        let left = CGRect(x: s1.minX - 40 - 180, y: s2.midY - 20, width: 180, height: 40)
        for script in [#"sticky-note "S14" above "S3" size: 140x100"#, #"sticky-note "S15" left of "S2" size: 180x40 text: "S15 text""#,
                       "sticky-note \"S14\" above \"S3\" size: 140x100\nsticky-note \"S15\" left of \"S2\" size: 180x40 text: \"S15 text\""] {
            let drew = try board.draw(script, dryRun: true)
            if script.contains("S14") {
                expectEqual(drew.at("S14"), above, script)
                expectEqual(drew.pushed("S14"), ["S1"], script)
            }
            if script.contains("S15") {
                expectEqual(drew.at("S15"), left, script)
                expectEqual(drew.pushed("S15"), ["S1"], script)
            }
        }
        // Two legends in the corners of a view half on an empty frame.
        let framed = try ZoneBoard()
        defer { framed.stop() }
        try framed.start(#"sticky-note "Frame" size: 3000x3000"#)
        let frame = try framed.box("Frame")
        framed.look(from: CGPoint(x: frame.minX - 720, y: frame.minY + 500))
        let view = framed.view
        let legends = try framed.draw(#"""
            sticky-note "L1" inside view top-right size: 200x200 text: "1"
            sticky-note "L2" inside view bottom-right size: 200x200 text: "2"
            """#, dryRun: true)
        expectEqual(legends.at("L1"), CGRect(origin: CGPoint(x: frame.minX - 40 - 200, y: view.minY + 40), size: squareSize))
        expectEqual(legends.at("L2"), CGRect(origin: CGPoint(x: frame.minX - 40 - 200, y: view.maxY - 40 - 200), size: squareSize))
        expectEqual(legends.pushed("L1"), ["Frame"])
        expectEqual(legends.pushed("L2"), ["Frame"])
        // Two cards lined up with an empty lane: each is held where it would land in it, and the
        // hint offers placing it elsewhere, then says how to start the lane.
        let lanes = try ZoneBoard()
        defer { lanes.stop() }
        try lanes.start(#"""
            sticky-note "Todo" size: 320x1100
            sticky-note "Doing" right of "Todo" (gap: 40) size: 320x1100
            """#)
        try lanes.start(#"""
            subboard "T1" inside "Todo" top-center size: 240x200
            subboard "T2" below "T1" size: 240x200
            """#)
        for script in [#"subboard "T1" left level with "Doing""#, "subboard \"T1\" left level with \"Doing\"\nsubboard \"T2\" left level with \"Doing\""] {
            let lined = try lanes.draw(script, dryRun: true)
            expectEqual(lined.reason, "unordered", script)
            expectEqual(lined.message, #""T1" is left level with "Doing" and can't move, but it overlaps "Doing""#, script)
            expectEqual(lined.hint, #""Doing" holds nothing yet, so it's in the way: place it elsewhere, or, if "Doing" is meant to hold shapes, place a first one inside it"#, script)
        }
        let doing = try lanes.box("Doing"), t2 = try lanes.box("T2")
        let started = try lanes.draw(#"""
            subboard "T1" inside "Doing" top-center
            subboard "T2" left level with "Doing"
            """#, dryRun: true)
        expectEqual(started.at("T1"), CGRect(x: doing.midX - 120, y: doing.minY + 40, width: 240, height: 200))
        expectEqual(started.at("T2"), CGRect(x: doing.minX, y: t2.minY, width: 240, height: 200))
        expectEqual(started.pushed("T2"), [])
        expectEqual(started.warnings.filter { !$0.contains("outside the view") }, [])
        // An empty note is such a region too, and a card on it would cover its words: placing it
        // elsewhere comes first.
        try lanes.start(#"""
            sticky-note "Big" below "Todo" (gap: 400) size: 900x700 text: "the user's long words"
            subboard "Card" left of "Big" size: 240x200
            """#)
        let onNote = try lanes.draw(#"subboard "Card" left level with "Big""#, dryRun: true)
        expectEqual(onNote.reason, "unordered")
        expectEqual(onNote.message, #""Card" is left level with "Big" and can't move, but it overlaps "Big""#)
        expectEqual(onNote.hint, #""Big" holds nothing yet, so it's in the way: place it elsewhere, or, if "Big" is meant to hold shapes, place a first one inside it"#)
    },
    test("a shape placed inside an empty zone is one it holds, whatever line it's on: a shape landing on the zone in the same script sits among it") {
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"""
            sticky-note "A" text: "a"
            sticky-note "Zone" right of "A" size: 900x600
            """#)
        let a = try b.box("A"), zone = try b.box("Zone")
        let alone = try b.draw(#"sticky-note "Probe" right of "A" (gap: 200) size: 160x100"#, dryRun: true)
        expectEqual(alone.at("Probe"), CGRect(x: zone.maxX + 40, y: a.midY - 50, width: 160, height: 100))
        expectEqual(alone.pushed("Probe"), ["Zone"])
        for script in ["sticky-note \"In\" inside \"Zone\" bottom-right text: \"in\"\nsticky-note \"Probe\" right of \"A\" (gap: 200) size: 160x100",
                       "sticky-note \"Probe\" right of \"A\" (gap: 200) size: 160x100\nsticky-note \"In\" inside \"Zone\" bottom-right text: \"in\""] {
            let drew = try b.draw(script, dryRun: true)
            expectEqual(drew.at("In"), corner("bottom-right", of: zone, noteSize), script)
            expectEqual(drew.at("Probe"), CGRect(x: a.maxX + 200, y: a.midY - 50, width: 160, height: 100), script)
            expectEqual(drew.pushed("Probe"), [], script)
            expectEqual(drew.warnings, [], script)
        }
    },
    test("zoomed into a frame that holds the whole view, a shape with nothing to hang on is drawn in the frame, in view, clear of what's on it") {
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"sticky-note "Frame" size: 6000x5000"#)
        let frame = try b.box("Frame")
        b.look(from: CGPoint(x: frame.minX + 2000, y: frame.minY + 1500))
        let view = b.view
        expect(frame.contains(view), "the view is in the frame")
        let loose = try b.start(#"sticky-note "Loose" text: "drawn in view""#)
        expectEqual(loose.at("Loose"), CGRect(origin: CGPoint(x: view.midX - noteSize.width / 2, y: view.midY - noteSize.height / 2), size: noteSize))
        expectEqual(loose.row("Loose")?["inView"], true)
        expectEqual(loose.warnings, [])
        expect(try b.paints("Loose") > b.paints("Frame"), "it paints above the frame")
        // The next is drawn clear of it, still in view, with what's placed against it.
        let next = try b.draw(#"""
            sticky-note "Next" text: "next"
            sticky-note "Tag" below "Next" (gap: tight) size: 160x100
            """#, dryRun: true)
        let boxes = [try require(next.at("Next")), try require(next.at("Tag"))]
        let drawn = boxes[0].union(boxes[1])
        expect(view.contains(drawn), "\(drawn) is in view")
        // Each is clear of it by the anchor's clearance, 80, as the spot is found box by box.
        for box in boxes { expect(!box.intersects(try b.box("Loose").insetBy(dx: -80, dy: -80)), "\(box) is clear of Loose") }
        expectEqual(next.pushed("Next") + next.pushed("Tag"), [])
        // A frame that holds only part of the view, its middle too, is in the way, as before.
        b.look(from: CGPoint(x: frame.minX - 400, y: frame.minY + 1500))
        expect(!frame.contains(b.view) && frame.contains(CGPoint(x: b.view.midX, y: b.view.midY)), "the view's middle is on the frame")
        let beside = try b.draw(#"sticky-note "Beside" text: "beside""#, dryRun: true)
        expect(!(try require(beside.at("Beside"))).intersects(frame), "clear of the frame")
    },
    test("zoomed into an empty frame, a shape restated onto it beside a drawing in view sits on it, above it: the drawing is on it for a reason of its own") {
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"""
            sticky-note "A" text: "a"
            sticky-note "R" below "A" size: 120x80
            """#)
        try b.start(#"sticky-note "Frame" right of "A" (gap: 100) size: 4000x3000"#)
        let frame = try b.box("Frame")
        b.look(from: CGPoint(x: frame.minX + 300, y: frame.minY + 300))
        expect(frame.contains(b.view), "the view is in the frame")
        expect(try b.paints("R") < b.paints("Frame"), "R starts under the frame")
        // Moved onto the frame (overlap: allow, as the drawing is placed after it), R lands among
        // the drawing, so the frame is its zone, and it's raised above it.
        try b.start(#"""
            sticky-note "Loose" text: "drawn in view"
            sticky-note "R" right of "A" (gap: 400) size: 160x100 overlap: allow
            """#)
        expect(frame.contains(try b.box("R")), "R is on the frame")
        expect(try b.paints("R") > b.paints("Frame"), "R is raised above the frame")
        expect(try b.paints("Loose") > b.paints("Frame"), "the drawing paints above the frame")
    },
    test("a card in the view's corner, on a frame that holds the view, is in a legend's way") {
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"sticky-note "Frame" size: 4000x3000"#)
        try b.start(#"subboard "Corner" inside view top-right size: 240x200"#)
        let card = try b.box("Corner")
        // Across the card's bottom is the shorter way for a subboard, and past its
        // left for a square note.
        for (kind, at) in [("subboard", CGRect(x: 1160, y: card.maxY + 64, width: 240, height: 160)),
                           ("sticky-note", CGRect(origin: CGPoint(x: card.minX - 40 - 200, y: 40), size: squareSize))] {
            let size = kind == "sticky-note" ? " size: 200x200" : ""
            let legend = try b.draw("\(kind) \"Legend\" inside view top-right\(size)", dryRun: true)
            expectEqual(legend.at("Legend"), at, kind)
            expectEqual(legend.pushed("Legend"), ["Corner"], kind)
        }
    },
    test("a diagram of 20 shapes placed against each other over three scripts, and a zone of six: nothing overlaps but the zone and what it holds") {
        let b = try ZoneBoard()
        defer { b.stop() }
        try b.start(#"""
            sticky-note "Client" text: "Browser"
            sticky-note "Gateway" right of "Client" size: 160x100
            sticky-note "Auth" right of "Gateway" text: "Auth service"
            subboard "Billing" right of "Auth" size: 240x200
            sticky-note "Cache" below "Gateway" size: 200x140
            sticky-note "DB" below "Auth" size: 160x100
            subboard "Reports" below "Billing" size: 240x200
            sticky-note "Logs" below "Client" text: "Log sink"
            sticky-note "Queue" below "Cache" size: 200x140
            subboard "Worker" right of "Queue" size: 240x200
            edge "Client" -> "Logs"
            edge "Gateway" -> "Auth" channel: none
            edge "Billing" -> "Reports"
            """#)
        try b.start(#"""
            sticky-note "CDN" left of "Gateway" size: 160x100
            sticky-note "Metrics" right of "Auth" size: 200x140
            sticky-note "Alerts" below "Cache" text: "Pager"
            subboard "Invoices" right of "Metrics" size: 240x200
            sticky-note "Replica" below "DB" size: 160x100
            sticky-note "Audit" above "Auth" text: "Who did what"
            sticky-note "Search" above "Gateway" size: 200x140
            subboard "Export" below "Reports" size: 240x200
            sticky-note "Backup" left of "Logs" size: 160x100
            sticky-note "Notes" right of "Worker" text: "misc"
            edge "Auth" -> "Audit"
            edge "Reports" -> "Export"
            """#)
        expectEqual(b.overlaps(), [])
        // Restated, moved against others, onto neighbors.
        try b.start(#"""
            sticky-note "DB" right of "Cache" size: 160x100
            sticky-note "Search" below "Logs" size: 160x100
            sticky-note "Audit" right of "Billing"
            subboard "Worker" below "Queue"
            """#)
        expectEqual(b.overlaps(), [])
        try b.start(#"sticky-note "Platform" below board size: 1400x640"#)
        try b.start(#"""
            sticky-note "P1" inside "Platform" top-left text: "p1"
            subboard "P2" right of "P1" size: 240x200
            sticky-note "P3" right of "P2" size: 200x140
            sticky-note "P4" right of "P3" size: 160x100
            sticky-note "P5" below "P1" size: 160x100
            sticky-note "P6" right of "P5" text: "p6"
            """#)
        expectEqual(b.shapes.count, 27)
        expectEqual(b.overlaps(besides: Set(["P1", "P2", "P3", "P4", "P5", "P6"].map { ["Platform", $0] })), [])
    },
])
