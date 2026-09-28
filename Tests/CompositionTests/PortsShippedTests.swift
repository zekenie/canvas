import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Checklists
import Clipboard
import Composition
import CoreGraphics
import Foundation
import LanguageModels
import Locking
import Mentions
import Schemas
import Selection
import StickyNotes
import TaskCards
import TestKit
import Titles
import Validation

// Ports as shipped, on real notes, task cards and schema cards: a note links to a note, a task to a
// task, a schema to a schema. This target doesn't import Ports, so it reads an arrow's channel where
// the board keeps it (its added values, as BoardCodec writes them), and finds the dots by where
// they're drawn: 12 points out from the middle of a side, at zoom 1.

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

/// Titled, so it has no issues and no red outline.
@MainActor private func task(_ frame: CGRect, title: String = "Ship it") -> AnyShapeRecord {
    var task = AnyShapeRecord(ShapeRecord(TaskCard(frame: frame)))
    task[TitleProperty.self] = title
    return task
}

/// Named, so it's clear which is which; as tall as an empty card.
@MainActor private func schemaCard(_ frame: CGRect, title: String) -> AnyShapeRecord {
    var card = SchemaCard(frame: frame)
    card.setTitle(title)
    card.frame = frame
    return AnyShapeRecord(ShapeRecord(card))
}

/// The shipped plugins on a board of `shapes`, their clipboard on `pasteboard`.
@MainActor private func shipped(_ shapes: [AnyShapeRecord], _ pasteboard: NSPasteboard) -> EditorHarness {
    EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(shapes: shapes), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
}

/// The arrows on the board.
@MainActor private func arrows(_ h: EditorHarness) -> [ShapeRecord<Arrow>] {
    h.editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
}

/// The channel a shape was drawn on, as its board saves it: nil for an arrow the arrow tool drew.
@MainActor private func channel(of id: ShapeID, in editor: CanvasEditor) throws -> JSONValue? {
    let record = try require(editor.document[id])
    let data = try BoardCodec(registry: editor.registry).encode(CanvasDocument(shapes: [record]))
    return try JSONDecoder().decode(JSONValue.self, from: data)["shapes"]?.arrayValue?.first?["added"]?["channel"]
}

/// What the stickies' and the tasks' channels are called on a board.
private let noteLink = JSONValue.string(String(describing: NoteLink.id))
private let taskLink = JSONValue.string(String(describing: TaskLink.id))
private let schemaLink = JSONValue.string(String(describing: SchemaLink.id))

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
    test("hovering a note shows its dots on the left, right and bottom, none on top; a task's on all four; each in its channel's color, with the open hand") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let noteFrame = CGRect(x: 100, y: 100, width: 200, height: 200), taskFrame = CGRect(x: 440, y: 100, width: 240, height: 200)
        let h = shipped([note(noteFrame), task(taskFrame)], pasteboard)
        let size = CGSize(width: 740, height: 360)
        let rest = renderBitmap(h.editor, size: size)
        for (frame, sides, color, name) in [(noteFrame, [Side.right, .bottom, .left], NoteLink.color, "note"),
                                            (taskFrame, Side.allCases, TaskLink.color, "task")] {
            h.move(to: center(frame))
            let hovered = renderBitmap(h.editor, size: size)
            for side in Side.allCases {
                let dot = side.dot(of: frame)
                if sides.contains(side) {
                    expect(changedPixels(rest, hovered, in: around(dot)) > 40, "the \(name)'s \(side) dot shows")
                    expectNear(pixel(hovered, at: dot), restingDot(color, over: pixel(rest, at: dot)), "the \(name)'s \(side) dot")
                } else {
                    expectEqual(changedPixels(rest, hovered, in: around(dot)), 0, "the \(name) has no \(side) dot")
                }
            }
            for side in Side.allCases {
                h.move(to: side.dot(of: frame))
                expectEqual(h.editor.hoveredButton != nil, sides.contains(side), "the pointer on the \(name)'s \(side) dot")
                expectEqual(h.editor.cursor, sides.contains(side) ? .openHand : .standard, "the \(name)'s \(side)")
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
    test("a drag from a note's dot, over a task card, doesn't bind or outline the task, which the other note is; released there, nothing is drawn") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 200, height: 200), taskFrame = CGRect(x: 500, y: 100, width: 240, height: 200)
        let bFrame = CGRect(x: 100, y: 500, width: 200, height: 200)
        let h = shipped([note(aFrame), task(taskFrame), note(bFrame)], pasteboard)
        let before = h.editor.document
        let size = CGSize(width: 800, height: 760)
        let rest = renderBitmap(h.editor, size: size)
        h.connect(from: .right, of: aFrame, to: center(taskFrame), release: false)
        let drawn = try require(arrows(h).first, "the arrow being drawn")
        expectEqual(drawn.props.end.binding, nil, "its end is free over the task")
        expectEqual(h.editor.hintedShapeID, nil, "the task isn't hinted")
        let drawing = renderBitmap(h.editor, size: size)
        // Just outside the other note's left side, and the task's, well away from the arrow.
        expect(pixel(drawing, at: CGPoint(x: 99, y: 620)) != pixel(rest, at: CGPoint(x: 99, y: 620)), "the other note, which could take it, is outlined")
        expectEqual(pixel(drawing, at: CGPoint(x: 499, y: 270)), pixel(rest, at: CGPoint(x: 499, y: 270)), "the task, which couldn't, isn't")
        h.release()
        expectEqual(h.editor.document, before)
    },
    test("a drag from a note's dot to where a task covers another note binds the note beneath, seeing through the task") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 200, height: 200), bFrame = CGRect(x: 500, y: 100, width: 200, height: 200)
        let b = note(bFrame)
        let h = shipped([note(aFrame), b, task(CGRect(x: 560, y: 60, width: 240, height: 200))], pasteboard)
        h.connect(from: .right, of: aFrame, to: CGPoint(x: 620, y: 200))
        expectEqual(arrows(h).first?.props.end.binding?.shapeID, b.id)
    },
    test("a drag from a task's dot to a note draws nothing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let taskFrame = CGRect(x: 100, y: 100, width: 240, height: 200), noteFrame = CGRect(x: 500, y: 100, width: 200, height: 200)
        let h = shipped([task(taskFrame), note(noteFrame)], pasteboard)
        let before = h.editor.document
        h.connect(from: .right, of: taskFrame, to: center(noteFrame))
        expectEqual(h.editor.document, before)
    },
    test("a drag from a task's dot to another task draws an arrow on the task-link channel, bound to both") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 240, height: 200), bFrame = CGRect(x: 100, y: 440, width: 240, height: 200)
        let a = task(aFrame), b = task(bFrame, title: "Test it")
        let h = shipped([a, b], pasteboard)
        h.connect(from: .bottom, of: aFrame, to: center(bFrame))
        let arrow = try require(arrows(h).first)
        expectEqual(arrows(h).count, 1)
        expectEqual(arrow.props.start.binding?.shapeID, a.id)
        expectEqual(arrow.props.end.binding?.shapeID, b.id)
        expectEqual(try channel(of: arrow.id, in: h.editor), taskLink)
    },
    test("a schema card's dots are on all four sides, in its accent; a drag from one to another card draws an arrow on the schema-link channel, bound to both, and to a task nothing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 240, height: 89), bFrame = CGRect(x: 100, y: 400, width: 240, height: 89)
        let taskFrame = CGRect(x: 500, y: 100, width: 240, height: 200)
        let a = schemaCard(aFrame, title: "Customer"), b = schemaCard(bFrame, title: "Order")
        let h = shipped([a, b, task(taskFrame)], pasteboard)
        let size = CGSize(width: 800, height: 560)
        let rest = renderBitmap(h.editor, size: size)
        h.move(to: center(aFrame))
        let hovered = renderBitmap(h.editor, size: size)
        for side in Side.allCases {
            let dot = side.dot(of: aFrame)
            expect(changedPixels(rest, hovered, in: around(dot)) > 40, "the card's \(side) dot shows")
            expectNear(pixel(hovered, at: dot), restingDot(SchemaLink.color, over: pixel(rest, at: dot)), "the card's \(side) dot")
        }
        let before = h.editor.document
        h.connect(from: .right, of: aFrame, to: center(taskFrame))
        expectEqual(h.editor.document, before, "a card links to no task")
        h.connect(from: .bottom, of: aFrame, to: center(bFrame))
        let arrow = try require(arrows(h).first)
        expectEqual(arrows(h).count, 1)
        expectEqual(arrow.props.start.binding?.shapeID, a.id)
        expectEqual(arrow.props.end.binding?.shapeID, b.id)
        expectEqual(try channel(of: arrow.id, in: h.editor), schemaLink)
    },
    test("a titled, locked note with a checklist shows its dots whole: no pixel is both a dot's and the pill's, the lock chip's or the checklist chip's") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let frame = CGRect(x: 100, y: 100, width: 200, height: 200)
        let size = CGSize(width: 400, height: 340)
        let sides = [Side.right, .bottom, .left]
        // The note plain or with all three, at rest and with the pointer on each dot (lit, with its halo).
        @MainActor func renders(decorated: Bool) -> (rest: NSBitmapImageRep, lit: [Side: NSBitmapImageRep]) {
            var record = note(frame, text: "Buy milk")
            if decorated {
                record[TitleProperty.self] = "A title much longer than the note is wide"
                record[ChecklistProperty.self] = [ChecklistItem(text: "oat milk")]
                record[LockedProperty.self] = true
            }
            let h = shipped([record], pasteboard)
            let rest = renderBitmap(h.editor, size: size)
            var lit: [Side: NSBitmapImageRep] = [:]
            for side in sides {
                h.move(to: center(frame))
                h.move(to: side.dot(of: frame))
                lit[side] = renderBitmap(h.editor, size: size)
            }
            return (rest, lit)
        }
        let plain = renders(decorated: false), decorated = renders(decorated: true)
        expect(changedPixels(plain.rest, decorated.rest, in: CGRect(x: 100, y: 75, width: 170, height: 12)) > 1000, "the pill")
        expect(changedPixels(plain.rest, decorated.rest, in: CGRect(x: 286, y: 77, width: 10, height: 10)) > 90, "the lock")
        expect(changedPixels(plain.rest, decorated.rest, in: CGRect(x: 270, y: 94, width: 36, height: 12)) > 100, "the checklist chip")
        for side in sides {
            let plainLit = try require(plain.lit[side]), lit = try require(decorated.lit[side])
            for dot in sides.map({ $0.dot(of: frame) }) {
                expectEqual(changedPixels(plainLit, lit, in: around(dot, 13)), 0, "with the \(side) dot lit, every dot as a plain note's")
            }
            var both = 0
            for y in 50..<340 {
                for x in 50..<360 {
                    let point = CGPoint(x: x, y: y), under = pixel(decorated.rest, at: point)
                    if pixel(lit, at: point) != under && pixel(plain.rest, at: point) != under { both += 1 }
                }
            }
            expectEqual(both, 0, "with the \(side) dot lit, no pixel is both a dot's and a decoration's")
        }
    },
    test("a locked task with a checklist shows all four dots whole, clear of its chips") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let frame = CGRect(x: 100, y: 100, width: 240, height: 200)
        let size = CGSize(width: 440, height: 340)
        @MainActor func renders(decorated: Bool) -> (rest: NSBitmapImageRep, lit: [Side: NSBitmapImageRep]) {
            var record = task(frame)
            if decorated {
                record[ChecklistProperty.self] = [ChecklistItem(text: "Spec"), ChecklistItem(text: "Build")]
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
        expect(changedPixels(plain.rest, decorated.rest, in: CGRect(x: 326, y: 77, width: 10, height: 10)) > 90, "the lock")
        for side in Side.allCases {
            let plainLit = try require(plain.lit[side]), lit = try require(decorated.lit[side])
            for dot in Side.allCases.map({ $0.dot(of: frame) }) {
                expectEqual(changedPixels(plainLit, lit, in: around(dot, 13)), 0, "with the \(side) dot lit, every dot as a plain task's")
            }
            var both = 0
            for y in 50..<340 {
                for x in 50..<400 {
                    let point = CGPoint(x: x, y: y), under = pixel(decorated.rest, at: point)
                    if pixel(lit, at: point) != under && pixel(plain.rest, at: point) != under { both += 1 }
                }
            }
            expectEqual(both, 0, "with the \(side) dot lit, no pixel is both a dot's and a chip's")
        }
    },
    test("in the arrow tool a note shows no dots, and a drag from where one would be draws the arrow tool's arrow, with no channel") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 200, height: 200), bFrame = CGRect(x: 500, y: 100, width: 200, height: 200)
        let b = note(bFrame)
        let h = shipped([note(aFrame), b], pasteboard)
        let size = CGSize(width: 760, height: 360)
        let rest = renderBitmap(h.editor, size: size)
        h.key("a")
        h.move(to: center(aFrame))
        h.move(to: Side.right.dot(of: aFrame))
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.button(atViewPoint: Side.right.dot(of: aFrame)), nil)
        let hovered = renderBitmap(h.editor, size: size)
        for side in Side.allCases {
            expectEqual(changedPixels(rest, hovered, in: around(side.dot(of: aFrame), 13)), 0, "no \(side) dot")
        }
        h.press()
        h.drag(to: center(bFrame), speed: 3)
        h.release()
        let arrow = try require(arrows(h).first)
        expectEqual(arrow.props.end.binding?.shapeID, b.id)
        expectEqual(try channel(of: arrow.id, in: h.editor), nil)
        // Back in the select tool, the dots show again as the pointer comes over the note.
        h.key("v")
        h.move(to: center(aFrame))
        expect(changedPixels(rest, renderBitmap(h.editor, size: size), in: around(Side.left.dot(of: aFrame))) > 40, "the left dot")
    },
    test("a board with an arrow drawn from a note's dot saves its channel, in format 3, and opens with it: re-aimed, it binds to a note but not to a task") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let aFrame = CGRect(x: 100, y: 100, width: 200, height: 200), bFrame = CGRect(x: 500, y: 100, width: 200, height: 200)
        let cFrame = CGRect(x: 500, y: 460, width: 200, height: 200), taskFrame = CGRect(x: 100, y: 460, width: 240, height: 200)
        let c = note(cFrame)
        let h = shipped([note(aFrame), note(bFrame), c, task(taskFrame)], pasteboard)
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
        // Opened, the arrow keeps to its channel: its end, dragged onto the task, binds to nothing;
        // onto a note, to the note.
        let opened = shipped(loaded.document.shapes, pasteboard)
        expectEqual(try channel(of: arrow, in: opened.editor), noteLink)
        opened.click(at: CGPoint(x: 400, y: 200))
        expectEqual(opened.editor.selection, arrow)
        for (target, bound) in [(taskFrame, nil as ShapeID?), (cFrame, c.id)] {
            let end = opened.view(try require(opened.editor.arrowGeometry(of: arrow)).endHandle)
            opened.move(to: end)
            opened.press()
            opened.drag(to: center(target), speed: 3)
            opened.release()
            expectEqual(opened.editor.document[arrow]?.typed(as: Arrow.self)?.props.end.binding?.shapeID, bound)
        }
    },
    test("arrows drawn with the arrow tool keep no channel: between ellipses the board writes format 1, as the app without arrow-ports does, byte for byte") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = shipped([], pasteboard)
        for x in [200.0, 600] {
            h.key("o")
            h.click(at: CGPoint(x: x, y: 200))
        }
        h.key("a")
        h.press(at: CGPoint(x: 200, y: 200))
        h.drag(to: CGPoint(x: 600, y: 200), speed: 3)
        h.release()
        let arrow = try require(arrows(h).first)
        expect(arrow.props.start.binding != nil && arrow.props.end.binding != nil, "bound at both ends")
        let data = try BoardCodec(registry: h.editor.registry).encode(h.editor.document)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        expectEqual(json["format"], 1)
        expectEqual(try require(json["shapes"]?.arrayValue).map { $0["added"] }, [nil, nil, nil])
        let withoutArrowPorts = try Registry(plugins: ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel()).filter { $0.id != "arrow-ports" })
        expectEqual(try BoardCodec(registry: withoutArrowPorts).encode(h.editor.document), data)
        // On a board of notes, which has added values (their checklists), the welcome board's arrows
        // add none.
        let welcome = try JSONDecoder().decode(JSONValue.self, from: BoardCodec(registry: h.editor.registry).encode(
            ShippedPlugins.makeEditor(scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel()).document))
        expectEqual(welcome["versions"]?["added"], .object(["checklist": 0]))
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
        for side in [Side.left, .bottom, .right] {
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
        for side in [Side.right, .bottom, .left] {
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
