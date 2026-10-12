import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import Connections
import CoreGraphics
import Foundation
import Frames
import LanguageModels
import Locking
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles
import Types
import Validation

// Ports as shipped, on real notes and subboards: a note links to a note, and a subboard to a note and
// to a subboard, and they to it. A frame has no ports.
// This file uses none of Ports' own API (`ChannelProperty`, `PortSide`), so it reads an arrow's
// channel where the board keeps it (its added values, as BoardCodec writes them), and finds the
// dots by where they're drawn: 12 points out from the middle of a side, at zoom 1.

/// A side of a shape, and where its dot would be.
private enum Side: CaseIterable {
    case top, right, bottom, left

    func dot(of frame: CGRect) -> CGPoint {
        switch self {
        case .top: CGPoint(x: frame.midX, y: frame.minY - 12)
        case .right: CGPoint(x: frame.maxX + 12, y: frame.midY)
        case .bottom: CGPoint(x: frame.midX, y: frame.maxY + 12)
        case .left: CGPoint(x: frame.minX - 12, y: frame.midY)
        }
    }
}

private func center(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

/// A square of view points around a dot: `radius` 6 holds a resting dot and its ring, 13 a lit one's halo.
private func around(_ point: CGPoint, _ radius: CGFloat = 6) -> CGRect {
    CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
}

@MainActor private func note(_ frame: CGRect, text: String = "Hi") -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(StickyNote(frame: frame, text: MentionText(plain: text))))
}

/// A subboard in `frame`, untitled (no pill over its top dot).
@MainActor private func subboard(_ frame: CGRect) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(Subboard(frame: frame)))
}

/// The shipped plugins on a board of `shapes`, their clipboard on `pasteboard`.
@MainActor private func shipped(_ shapes: [AnyShapeRecord], _ pasteboard: NSPasteboard) -> EditorHarness {
    EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(shapes: shapes), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
}

/// The arrows on the board.
@MainActor private func arrows(_ h: EditorHarness) -> [ShapeRecord<Arrow>] {
    h.editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
}

/// The channel a shape was drawn on, as its board saves it: nil for an arrow on none.
@MainActor private func channel(of id: ShapeID, in editor: CanvasEditor) throws -> JSONValue? {
    let record = try require(editor.document[id])
    let data = try BoardCodec(registry: editor.registry).encode(CanvasDocument(shapes: [record]))
    return try JSONDecoder().decode(JSONValue.self, from: data)["shapes"]?.arrayValue?.first?["added"]?["channel"]
}

/// What the stickies' and the subboards' channels are called on a board.
private let noteLink = JSONValue.string(String(describing: NoteLink.id))
private let subboardLink = JSONValue.string(String(describing: SubboardLink.id))

/// A resting dot's middle: its channel's color at 60% over what's under it, in the renders' device RGB.
@MainActor private func restingDot(_ color: NSColor, over under: [Int]) -> [Int] {
    var rgb: [CGFloat] = [0, 0, 0]
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        let resolved = color.usingColorSpace(.deviceRGB)!
        rgb = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
    }
    return (0..<3).map { channel in
        let mixed: CGFloat = rgb[channel] * 255 * 0.6 + CGFloat(under[channel]) * 0.4
        return Int(mixed.rounded())
    }
}

@MainActor private func expectNear(_ actual: [Int], _ expected: [Int], within tolerance: Int = 4, _ message: String, line: UInt = #line) {
    expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }, "\(message): \(actual.prefix(3)), expected about \(expected)", line: line)
}

extension EditorHarness {
    /// Hovers the shape in `frame`, presses its dot on `side`, drags fast to `point` and, unless
    /// told not to, releases there.
    fileprivate func connect(from side: Side, of frame: CGRect, to point: CGPoint, release: Bool = true) {
        move(to: center(frame))
        move(to: side.dot(of: frame))
        press()
        drag(to: point, speed: 3)
        if release { self.release() }
    }
}

@MainActor let portsShippedTests = Suite("Ports, as shipped", [
    test("hovering a note or a subboard shows its dots on all four sides, the top one too; each in its channel's color, with the open hand") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let noteFrame = CGRect(x: 100, y: 100, width: 200, height: 200)
        let subFrame = CGRect(x: 100, y: 400, width: 240, height: 160)
        let h = shipped([note(noteFrame), subboard(subFrame)], pasteboard)
        let size = CGSize(width: 740, height: 640)
        let rest = renderBitmap(h.editor, size: size)
        for (frame, color, name) in [(noteFrame, NoteLink.color, "note"), (subFrame, SubboardLink.color, "subboard")] {
            h.move(to: center(frame))
            let hovered = renderBitmap(h.editor, size: size)
            for side in Side.allCases {
                let dot = side.dot(of: frame)
                expect(changedPixels(rest, hovered, in: around(dot)) > 40, "the \(name)'s \(side) dot shows")
                expectNear(pixel(hovered, at: dot), restingDot(color, over: pixel(rest, at: dot)), "the \(name)'s \(side) dot")
            }
            for side in Side.allCases {
                h.move(to: side.dot(of: frame))
                expect(h.editor.hoveredButton != nil, "the pointer on the \(name)'s \(side) dot")
                expectEqual(h.editor.cursor, .openHand, "the \(name)'s \(side)")
            }
        }
    },
    test("a drag from a note's dot to another note draws an arrow on the note-link channel, bound to both, and leaves the selection and the tool alone") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 200, height: 200), bFrame = CGRect(x: 500, y: 100, width: 200, height: 200)
        let a = note(aFrame), b = note(bFrame)
        let h = shipped([a, b], pasteboard)
        let size = CGSize(width: 760, height: 360)
        let rest = renderBitmap(h.editor, size: size)
        h.connect(from: .right, of: aFrame, to: center(bFrame))
        let arrow = try require(arrows(h).first)
        expectEqual(arrows(h).count, 1)
        expectEqual(arrow.props.start.binding?.shapeID, a.id)
        expectEqual(arrow.props.end.binding?.shapeID, b.id)
        expectEqual(try channel(of: arrow.id, in: h.editor), noteLink)
        expectEqual(h.editor.selectedShapeIDs, [])
        expectEqual(h.editor.currentToolID, .select)
        // Released over the other note, the dots are its, where the pointer is, not the first's.
        let after = renderBitmap(h.editor, size: size)
        expect(changedPixels(rest, after, in: around(Side.right.dot(of: bFrame))) > 40, "the other note's right dot")
        expectEqual(changedPixels(rest, after, in: around(Side.left.dot(of: aFrame))), 0, "the first note's left dot")
    },
    test("a drag from a note's dot to a subboard draws an arrow on the note-link channel, bound to both") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let noteFrame = CGRect(x: 100, y: 100, width: 200, height: 200)
        let subFrame = CGRect(x: 560, y: 220, width: 240, height: 160)
        let n = note(noteFrame), sub = subboard(subFrame)
        let h = shipped([n, sub], pasteboard)
        h.connect(from: .right, of: noteFrame, to: center(subFrame))
        expectEqual(arrows(h).map { [$0.props.start.binding?.shapeID, $0.props.end.binding?.shapeID] }, [[n.id, sub.id]])
        expectEqual(try arrows(h).map { try channel(of: $0.id, in: h.editor) }, [noteLink])
        expectEqual(h.editor.selectedShapeIDs, [])
        expectEqual(h.editor.currentToolID, .select)
    },
    test("a drag from a subboard's dot draws an arrow on the channel the shape it ends on takes, bound to both: note-link to a note, subboard-link to another subboard") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let subFrame = CGRect(x: 400, y: 300, width: 240, height: 160), otherFrame = CGRect(x: 400, y: 650, width: 240, height: 160)
        let noteFrame = CGRect(x: 100, y: 100, width: 200, height: 200)
        let sub = subboard(subFrame), other = subboard(otherFrame), n = note(noteFrame)
        let h = shipped([sub, other, n], pasteboard)
        h.connect(from: .left, of: subFrame, to: center(noteFrame))
        h.connect(from: .bottom, of: subFrame, to: center(otherFrame))
        expectEqual(arrows(h).map { [$0.props.start.binding?.shapeID, $0.props.end.binding?.shapeID] },
                    [[sub.id, n.id], [sub.id, other.id]])
        expectEqual(try arrows(h).map { try channel(of: $0.id, in: h.editor) }, [noteLink, subboardLink])
        expectEqual(h.editor.selectedShapeIDs, [])
        expectEqual(h.editor.currentToolID, .select)
    },
    test("a drag from a subboard's dot outlines the shapes that take its link, a note, and not a frame, which has no ports: released over it, nothing is drawn") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let subFrame = CGRect(x: 100, y: 100, width: 240, height: 160)
        let noteFrame = CGRect(x: 500, y: 100, width: 200, height: 200), frameFrame = CGRect(x: 500, y: 400, width: 300, height: 200)
        let h = shipped([subboard(subFrame), note(noteFrame), AnyShapeRecord(ShapeRecord(Frame(frame: frameFrame)))], pasteboard)
        let before = h.editor.document
        let size = CGSize(width: 900, height: 640)
        let rest = renderBitmap(h.editor, size: size)
        h.connect(from: .right, of: subFrame, to: CGPoint(x: 420, y: 330), release: false)
        let drawing = renderBitmap(h.editor, size: size)
        // Just outside the left side of each, well away from the arrow being drawn.
        func leftSide(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.minX - 1, y: frame.midY) }
        expect(pixel(drawing, at: leftSide(noteFrame)) != pixel(rest, at: leftSide(noteFrame)), "the note, which takes it, is outlined")
        expectEqual(pixel(drawing, at: leftSide(frameFrame)), pixel(rest, at: leftSide(frameFrame)), "the frame, which doesn't, isn't")
        h.release()
        h.connect(from: .right, of: subFrame, to: center(frameFrame))
        expectEqual(h.editor.document, before, "a subboard links to no frame")
    },
    test("a titled, locked note shows its dots whole: no pixel is both a dot's and the pill's or the lock chip's, but its top dot's, which a long title runs under: it's drawn over the pill") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let frame = CGRect(x: 100, y: 100, width: 200, height: 200)
        let size = CGSize(width: 400, height: 340)
        // The sides the pill and the lock chip are clear of. The top dot is in the pill's row, 12 points above
        // the middle of the top edge, so a long title runs under it.
        let sides = [Side.right, .bottom, .left]
        let topDot = Side.top.dot(of: frame)
        // The note plain or with both, at rest and with the pointer on each dot (lit, with its halo).
        @MainActor func renders(decorated: Bool) -> (rest: NSBitmapImageRep, lit: [Side: NSBitmapImageRep]) {
            var record = note(frame, text: "Buy milk")
            if decorated {
                record[TitleProperty.self] = "A title much longer than the note is wide"
                record[LockedProperty.self] = true
            }
            let h = shipped([record], pasteboard)
            let rest = renderBitmap(h.editor, size: size)
            var lit: [Side: NSBitmapImageRep] = [:]
            for side in Side.allCases {
                h.move(to: center(frame))
                h.move(to: side.dot(of: frame))
                lit[side] = renderBitmap(h.editor, size: size)
            }
            return (rest, lit)
        }
        let plain = renders(decorated: false), decorated = renders(decorated: true)
        expect(changedPixels(plain.rest, decorated.rest, in: CGRect(x: 100, y: 75, width: 170, height: 12)) > 1000, "the pill")
        expect(changedPixels(plain.rest, decorated.rest, in: CGRect(x: 286, y: 77, width: 10, height: 10)) > 90, "the lock")
        for side in Side.allCases {
            let plainLit = try require(plain.lit[side]), lit = try require(decorated.lit[side])
            for dot in sides.map({ $0.dot(of: frame) }) {
                expectEqual(changedPixels(plainLit, lit, in: around(dot, 13)), 0, "with the \(side) dot lit, every other dot as a plain note's")
            }
            var both = 0
            for y in 50..<340 {
                for x in 50..<360 {
                    let point = CGPoint(x: x, y: y), under = pixel(decorated.rest, at: point)
                    if around(topDot, 13).contains(point) { continue }
                    if pixel(lit, at: point) != under && pixel(plain.rest, at: point) != under { both += 1 }
                }
            }
            expectEqual(both, 0, "with the \(side) dot lit, no pixel but the top dot's is both a dot's and a decoration's")
        }
        // Lit, the top dot's middle is its channel's color at full strength, over the pill as over a plain note.
        let plainTop = try require(plain.lit[.top]), litTop = try require(decorated.lit[.top])
        expectEqual(pixel(litTop, at: topDot), pixel(plainTop, at: topDot), "the top dot, over the pill")
    },
    test("in another tool a note shows no dots, and back in the select tool they show again") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 200, height: 200), bFrame = CGRect(x: 500, y: 100, width: 200, height: 200)
        let b = note(bFrame)
        let h = shipped([note(aFrame), b], pasteboard)
        let size = CGSize(width: 760, height: 360)
        let rest = renderBitmap(h.editor, size: size)
        h.key("h")
        h.move(to: center(aFrame))
        h.move(to: Side.right.dot(of: aFrame))
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.button(atViewPoint: Side.right.dot(of: aFrame)), nil)
        let hovered = renderBitmap(h.editor, size: size)
        for side in Side.allCases {
            expectEqual(changedPixels(rest, hovered, in: around(side.dot(of: aFrame), 13)), 0, "no \(side) dot")
        }
        // Back in the select tool, the dots show again as the pointer comes over the note.
        h.key("v")
        h.move(to: center(aFrame))
        expect(changedPixels(rest, renderBitmap(h.editor, size: size), in: around(Side.left.dot(of: aFrame))) > 40, "the left dot")
    },
    test("a board with an arrow drawn from a note's dot saves its channel, in format 3, and opens with it: re-aimed, it binds to a note or a subboard but not to a frame") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 200, height: 200), bFrame = CGRect(x: 500, y: 100, width: 200, height: 200)
        let cFrame = CGRect(x: 500, y: 460, width: 200, height: 200), frameFrame = CGRect(x: 100, y: 460, width: 240, height: 200)
        let subFrame = CGRect(x: 900, y: 460, width: 240, height: 160)
        let c = note(cFrame), sub = subboard(subFrame)
        let h = shipped([note(aFrame), note(bFrame), c, AnyShapeRecord(ShapeRecord(Frame(frame: frameFrame))), sub], pasteboard)
        h.connect(from: .right, of: aFrame, to: center(bFrame))
        let arrow = try require(arrows(h).first).id
        let codec = BoardCodec(registry: h.editor.registry)
        let data = try codec.encode(h.editor.document)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        expectEqual(json["format"], 3)
        expectEqual(json["versions"]?["added"]?["channel"], 0)
        let saved = try require(json["shapes"]?.arrayValue?.first { $0["kind"]?.stringValue == Arrow.kind.rawValue })
        expectEqual(saved["added"], .object(["channel": noteLink]))
        let loaded = try codec.decode(data)
        expectEqual(loaded.report, LoadReport())
        expectEqual(loaded.document, h.editor.document)
        // Opened, the arrow keeps to its channel: its end, dragged onto the frame, binds to nothing;
        // onto a note, to the note; onto a subboard, which takes every channel, to the subboard.
        let opened = shipped(loaded.document.shapes, pasteboard)
        expectEqual(try channel(of: arrow, in: opened.editor), noteLink)
        opened.click(at: CGPoint(x: 400, y: 200))
        expectEqual(opened.editor.selection, arrow)
        for (target, bound) in [(frameFrame, nil as ShapeID?), (cFrame, c.id), (subFrame, sub.id)] {
            let end = opened.view(try require(opened.editor.arrowGeometry(of: arrow)).endHandle)
            opened.move(to: end)
            opened.press()
            opened.drag(to: center(target), speed: 3)
            opened.release()
            expectEqual(opened.editor.document[arrow]?.typed(as: Arrow.self)?.props.end.binding?.shapeID, bound)
        }
    },
    test("an arrow drawn between subboards keeps to the subboard-link channel: re-aimed, its end binds to another subboard, and to no note") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 240, height: 160), bFrame = CGRect(x: 500, y: 100, width: 240, height: 160)
        let cFrame = CGRect(x: 500, y: 460, width: 240, height: 160), noteFrame = CGRect(x: 100, y: 460, width: 200, height: 200)
        let c = subboard(cFrame)
        let h = shipped([subboard(aFrame), subboard(bFrame), c, note(noteFrame)], pasteboard)
        h.connect(from: .right, of: aFrame, to: center(bFrame))
        let arrow = try require(arrows(h).first).id
        expectEqual(try channel(of: arrow, in: h.editor), subboardLink)
        h.click(at: CGPoint(x: 420, y: 180))
        expectEqual(h.editor.selection, arrow)
        for (target, bound) in [(noteFrame, nil as ShapeID?), (cFrame, c.id)] {
            let end = h.view(try require(h.editor.arrowGeometry(of: arrow)).endHandle)
            h.move(to: end)
            h.press()
            h.drag(to: center(target), speed: 3)
            h.release()
            expectEqual(h.editor.document[arrow]?.typed(as: Arrow.self)?.props.end.binding?.shapeID, bound)
        }
        expectEqual(try channel(of: arrow, in: h.editor), subboardLink, "re-aimed, it keeps its channel")
    },
    test("arrows on no channel keep none: between subboards the board writes format 1, as the app without arrow-ports does, byte for byte") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = shipped([], pasteboard)
        let subboards = [200.0, 600].map { x in h.add(Subboard(frame: CGRect(x: x, y: 200, width: 240, height: 160))) }
        expectEqual(h.editor.document.shapes.count, 2)
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        h.add(Arrow(start: bound(subboards[0]), end: bound(subboards[1])))
        let data = try BoardCodec(registry: h.editor.registry).encode(h.editor.document)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        expectEqual(json["format"], 1)
        expectEqual(try require(json["shapes"]?.arrayValue).map { $0["added"] }, [nil, nil, nil])
        let withoutArrowPorts = try Registry(plugins: ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel()).filter { $0.id != "arrow-ports" })
        expectEqual(try BoardCodec(registry: withoutArrowPorts).encode(h.editor.document), data)
        // Between notes, the welcome board's arrows add none either.
        let welcome = try JSONDecoder().decode(JSONValue.self, from: BoardCodec(registry: h.editor.registry).encode(
            ShippedPlugins.makeEditor(scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel()).document))
        let welcomeArrows = try require(welcome["shapes"]?.arrayValue).filter { $0["kind"]?.stringValue == Arrow.kind.rawValue }
        expectEqual(welcomeArrows.map { $0["added"] }, [nil, nil, nil])
    },
    test("a click or a double-click on a note's dot does nothing: no arrow, no note placed, the selection as it was; pressed, it shows the closed hand") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 200, height: 200), bFrame = CGRect(x: 500, y: 100, width: 200, height: 200)
        let b = note(bFrame)
        let h = shipped([note(aFrame), b], pasteboard)
        h.editor.selection = b.id
        let before = h.editor.document
        h.move(to: center(aFrame))
        h.move(to: Side.right.dot(of: aFrame))
        h.press()
        expectEqual(h.editor.cursor, .closedHand)
        h.release()
        h.click(clickCount: 2)
        expectEqual(h.editor.document, before)
        expectEqual(h.editor.selectedShapeIDs, [b.id])
    },
    test("a drag from a note's dot back onto the note, or onto empty canvas, draws nothing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 200, height: 200)
        let h = shipped([note(aFrame), note(CGRect(x: 500, y: 100, width: 200, height: 200))], pasteboard)
        let before = h.editor.document
        h.connect(from: .right, of: aFrame, to: CGPoint(x: 150, y: 150))
        expectEqual(h.editor.document, before, "back onto its own note")
        h.connect(from: .bottom, of: aFrame, to: CGPoint(x: 400, y: 500))
        expectEqual(h.editor.document, before, "onto empty canvas")
        expectEqual(h.editor.currentToolID, .select)
    },
    test("Escape lets go of a drag from a note's dot: nothing is drawn, and the note's dots don't stay behind while the pointer is held away from it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 200, height: 200), bFrame = CGRect(x: 500, y: 100, width: 200, height: 200)
        let h = shipped([note(aFrame), note(bFrame)], pasteboard)
        let before = h.editor.document
        let size = CGSize(width: 760, height: 360)
        let rest = renderBitmap(h.editor, size: size)
        h.connect(from: .right, of: aFrame, to: center(bFrame), release: false)
        expectEqual(arrows(h).count, 1, "the arrow being drawn")
        h.key("\u{1b}")
        expectEqual(h.editor.document, before)
        let held = renderBitmap(h.editor, size: size)
        for side in Side.allCases {
            expectEqual(changedPixels(rest, held, in: around(side.dot(of: aFrame))), 0, "the first note's \(side) dot, 300 points from the pointer")
        }
        h.release()
        expectEqual(h.editor.document, before)
        expectEqual(h.editor.currentToolID, .select)
    },
    test("a locked note keeps its ports: an arrow drawn from it, and one to it, bind it without shaking it; its lock chip still clicks") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 200, height: 200), bFrame = CGRect(x: 500, y: 100, width: 200, height: 200)
        let a = note(aFrame), b = note(bFrame)
        let h = shipped([a, b], pasteboard)
        h.editor.lock([a.id, b.id])
        let locked = h.editor.document
        h.connect(from: .right, of: aFrame, to: center(bFrame))
        h.connect(from: .bottom, of: bFrame, to: center(aFrame))
        expectEqual(arrows(h).map { [$0.props.start.binding?.shapeID, $0.props.end.binding?.shapeID] }, [[a.id, b.id], [b.id, a.id]])
        expectEqual([h.editor.document[a.id], h.editor.document[b.id]], [locked[a.id], locked[b.id]], "connecting doesn't change them")
        h.wait(16)
        expectEqual([h.editor.drawingOffset(of: a.id), h.editor.drawingOffset(of: b.id)], [.zero, .zero], "nor shakes them")
        // The lock chip, above the top-right corner, is a clickable adornment (Adornments' canvas
        // button), which a dot never covers.
        h.move(to: center(aFrame))
        h.move(to: CGPoint(x: aFrame.maxX - 9, y: aFrame.minY - 18))
        h.click()
        expect(!h.editor.isLocked(a.id), "unlocked")
    },
    test("a locked note's dots shake with it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let frame = CGRect(x: 100, y: 100, width: 200, height: 200)
        let a = note(frame)
        let h = shipped([a], pasteboard)
        h.editor.lock([a.id])
        let size = CGSize(width: 400, height: 360)
        // A drag tries to move it, which it refuses; let go of on it, its dots show as it shakes.
        h.move(to: center(frame))
        h.press()
        h.drag(to: CGPoint(x: 240, y: 200))
        h.release()
        var frames = 0
        while abs(h.editor.drawingOffset(of: a.id).x) < 2 && frames < 20 {
            h.wait(16)
            frames += 1
        }
        let offset = h.editor.drawingOffset(of: a.id)
        expect(abs(offset.x) >= 2, "shaking: \(offset)")
        let shaking = renderBitmap(h.editor, size: size)
        h.editor.pointerExited()
        let withoutDots = renderBitmap(h.editor, size: size)
        for side in Side.allCases {
            // The middle of the dot's pixels near where it should be now, clear of the note's
            // outline (10 points in): a dot left behind would pull it 2 points or more away.
            let dot = side.dot(of: frame), shaken = CGPoint(x: dot.x + offset.x, y: dot.y + offset.y)
            var sum = CGPoint.zero, count: CGFloat = 0
            for y in Int(shaken.y.rounded()) - 8..<Int(shaken.y.rounded()) + 8 {
                for x in Int(shaken.x.rounded()) - 8..<Int(shaken.x.rounded()) + 8 {
                    let point = CGPoint(x: x, y: y)
                    guard pixel(shaking, at: point) != pixel(withoutDots, at: point) else { continue }
                    sum = CGPoint(x: sum.x + point.x + 0.5, y: sum.y + point.y + 0.5)
                    count += 1
                }
            }
            expect(count > 40, "the \(side) dot shows")
            expectClose(CGPoint(x: sum.x / max(count, 1), y: sum.y / max(count, 1)), shaken, within: 0.5)
        }
    },
    test("an arrow drawn on a channel, validated against its schema, has no issues; copied with its notes, the copy keeps its channel and binds the copies") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 200, height: 200), bFrame = CGRect(x: 500, y: 100, width: 200, height: 200)
        let h = shipped([note(aFrame), note(bFrame)], pasteboard)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        h.connect(from: .right, of: aFrame, to: center(bFrame))
        let arrow = try require(arrows(h).first)
        expectEqual(h.editor.validation?.result(for: arrow.id), nil)
        expectEqual(h.editor.registry.schemaViolations(of: try require(h.editor.document[arrow.id])), [])
        h.editor.perform(.selectAll)
        h.editor.copySelection()
        let before = h.editor.document
        h.editor.paste()
        let copies = h.editor.shapes(since: before)
        let copy = try require(copies.first { $0.kind == Arrow.kind })
        let original = { (id: ShapeID?) in id.flatMap { id in copies.first { $0.id == id }?.copiedFrom } }
        let props = try require(copy.typed(as: Arrow.self)).props
        expectEqual(original(props.start.binding?.shapeID), arrow.props.start.binding?.shapeID)
        expectEqual(original(props.end.binding?.shapeID), arrow.props.end.binding?.shapeID)
        expectEqual(try channel(of: copy.id, in: h.editor), noteLink)
    },
])
