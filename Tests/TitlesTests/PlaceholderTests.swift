import Adornments
import AppKit
import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TableOfContents
import TestKit
import Titles

// A pill to grab on an untitled shape (`placeholderInPill`): boxes (CanvasTesting's) titled from a
// bridge, whose untitled pill says "Crate", dimmed.

/// Boxes titled from a bridge, Titles keeping the title, with "Crate" in the pill while untitled.
@MainActor func crateTitles(_ placeholder: String = "Crate", pill: Bool = true) -> Contributor {
    Contributor(id: "crate-titles") { $0.title(Box.self, pill: pill, placeholderInPill: placeholder) }
}

let crateFrame = CGRect(x: 60, y: 100, width: 200, height: 120)

extension CanvasEditor {
    /// Inserts a box named `name`, in a transaction of its own.
    @discardableResult
    func add(_ box: Box, named name: String?) -> ShapeID {
        var shape = ShapeRecord(box)
        shape[TitleProperty.self] = name
        transact { $0.insert(shape) }
        return shape.id
    }
}

/// The brightest pixel (by the sum of its red, green and blue) in a view rect.
@MainActor func brightest(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
    var best = 0
    for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
            best = max(best, pixel(rep, at: CGPoint(x: x, y: y)).prefix(3).reduce(0, +))
        }
    }
    return best
}

@MainActor let placeholderTests = Suite("Placeholder pills", [
    test("a kind that asks shows its placeholder in the pill while a shape is untitled, dimmed; titled, its title; blank, the placeholder again") {
        let editor = try titleEditor([crateTitles()])
        let box = editor.add(Box(crateFrame))
        expectEqual(editor.adornmentFrames(of: box).map(\.label), [AdornmentLabel(placeholder: "Crate")])
        expect(try require(editor.adornmentFrames(of: box).first).label.isPlaceholder)
        expectEqual(editor.title(box), nil, "it's no title: the shape is untitled")
        editor.rename(box, "Spares")
        expectEqual(editor.adornmentFrames(of: box).map(\.label), [AdornmentLabel("Spares")])
        expect(!(try require(editor.adornmentFrames(of: box).first).label.isPlaceholder))
        editor.rename(box, "  ")
        expectEqual(editor.adornmentFrames(of: box).map(\.label), [AdornmentLabel(placeholder: "Crate")])
        expectEqual(try require(editor.tableOfContents).entries.map { $0.label?.text }, ["box"], "the row is the kind's, as untitled")
    },
    test("kinds that don't ask see no change: no pill while untitled; nor with no pill at all, or a blank placeholder") {
        let discs = Contributor(id: "disc-titles") { $0.title(Disc.self, pill: false, placeholderInPill: "Disc") }
        let editor = try titleEditor([discs])
        let plaque = editor.add(Plaque(plaqueFrame))
        let disc = editor.add(Disc(crateFrame))
        expectEqual(editor.adornmentFrames(of: plaque), [], "a plaque doesn't ask")
        expectEqual(editor.adornmentFrames(of: disc), [], "a disc shows no pill")
        let blank = try titleEditor([crateTitles(" \n ")])
        expectEqual(blank.adornmentFrames(of: blank.add(Box(crateFrame))), [], "a blank placeholder is none")
    },
    test("it's laid out as a title is: as long as the same text titled, after the kind's symbol where it asks") {
        let cards = Contributor(id: "card-titles") { $0.title(Card.self, symbolInPill: true, placeholderInPill: "Crate") { $0.props.text } }
        let editor = try titleEditor([crateTitles(), CardsPlugin(), cards])
        let untitled = editor.add(Box(crateFrame))
        let titled = editor.add(Box(CGRect(x: 60, y: 300, width: 200, height: 120)), named: "Crate")
        let card = editor.add(Card(CGRect(x: 300, y: 100, width: 200, height: 120)))
        let placeholder = try require(editor.adornmentFrames(of: untitled).first), title = try require(editor.adornmentFrames(of: titled).first)
        expectEqual(placeholder.rect.size, title.rect.size)
        expectEqual(placeholder.rect.origin, title.rect.origin - CGPoint(x: 0, y: 200), "at the left end of the row above")
        expectEqual(editor.adornmentFrames(of: card).map(\.label), [AdornmentLabel(placeholder: "Crate", systemImage: "rectangle")],
                    "a derived title's kind may give one too")
    },
    test("its text is drawn dimmed: fainter than a title's, on the same capsule") {
        let editor = try titleEditor([crateTitles("Lobby")])
        let box = editor.add(Box(crateFrame))
        let pill = try require(editor.adornmentFrames(of: box).first).rect     // at 100%, view points as world units
        let placeholder = render(editor)
        editor.rename(box, "Lobby")
        expectEqual(try require(editor.adornmentFrames(of: box).first).rect, pill, "laid out alike")
        let titled = render(editor)
        let text = pill.insetBy(dx: 7, dy: 3)
        let fill = pixel(titled, at: CGPoint(x: pill.minX + 4, y: pill.midY)).prefix(3).reduce(0, +)
        expectEqual(pixel(placeholder, at: CGPoint(x: pill.minX + 4, y: pill.midY)), pixel(titled, at: CGPoint(x: pill.minX + 4, y: pill.midY)),
                    "the same capsule")
        let dim = brightest(placeholder, in: text), bright = brightest(titled, in: text)
        expect(dim > fill + 100, "its text shows: \(dim) over a fill of \(fill)")
        expect(bright > dim + 100, "fainter than a title's: \(dim), against \(bright)")
    },
    test("below 35%, on a shape drawn as a skeleton, it's a blank capsule, as long as the same title's") {
        let editor = try titleEditor([crateTitles()])
        let untitled = editor.add(Box(CGRect(x: 60 / 0.3, y: 100 / 0.3, width: 200 / 0.3, height: 120 / 0.3)))
        let titled = editor.add(Box(CGRect(x: 60 / 0.3, y: 400 / 0.3, width: 200 / 0.3, height: 120 / 0.3)), named: "Crate")
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let pill = editor.camera.toView(try require(editor.adornmentFrames(of: untitled).first).rect)
        expectClose(pill.width, editor.camera.toView(try require(editor.adornmentFrames(of: titled).first).rect).width, within: 0.001)
        let rendered = render(editor)
        let middle = pill.insetBy(dx: pill.height / 2, dy: 3)
        let colors = Set(stride(from: middle.minY, to: middle.maxY, by: 1).flatMap { y in
            stride(from: middle.minX, to: middle.maxX, by: 1).map { x in pixel(rendered, at: CGPoint(x: x, y: y)) }
        })
        expect(middle.width > 8, "\(pill)")
        expectEqual(colors.count, 1, "blank: \(colors)")
    },
    test("it's its shape's for the select tool and hover, as any pill: a press selects the shape, a drag moves it, and the menu is the shape's") {
        let h = try EditorHarness { try titleEditor([crateTitles()], scheduler: $0) }
        let box = h.add(Box(crateFrame))
        let pill = try require(h.editor.adornmentFrames(of: box).first).rect
        let on = CGPoint(x: pill.midX, y: pill.midY)
        expect(on.y < crateFrame.minY, "above the shape, outside it")
        expectEqual(h.editor.selectableShape(at: on), box, "what a press, a hover and a right-click there are on")
        h.move(to: on)
        expectEqual(h.editor.hovered, box)
        h.press(at: on)
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.drag(to: on + CGPoint(x: 30, y: 40))
        h.release()
        expectEqual(h.editor.document[box]?.box?.origin, crateFrame.origin + CGPoint(x: 30, y: 40), "a lone box follows from the press")
        expectEqual(h.editor.adornmentFrames(of: box).first?.rect, pill.offsetBy(dx: 30, dy: 40), "and its pill with it")
    },
])
