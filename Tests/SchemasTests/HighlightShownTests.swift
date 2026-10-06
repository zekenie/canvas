import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import Geometry
import LanguageModels
import Mentions
import ProseMaps
import Schemas
import TestKit

// A card's highlights as a person meets them: behind their words on the canvas and in the card's
// editor alike, and resting the pointer on them shows the part of the schema they say.

extension HighlightBench {
    /// The owner's card, 320 wide at (100, 100), its highlights landed.
    func jiraCard() -> ShapeID {
        let id = editor.add(SchemasTests.card(jiraSchema, prompt: jiraPrompt, at: CGPoint(x: 100, y: 100), width: 320))
        frame()
        settle()
        return id
    }

    /// Where the card's highlight of `words` is drawn, its first line, in world units.
    func line(of words: String, on id: ShapeID) throws -> CGRect {
        let card = try require(card(id))
        let text = card.props.prompt.stored as NSString
        let placed = placed(card)
        let index = try require(placed.firstIndex { text.substring(with: $0.range) == words }, "no highlight of \(words)")
        return try require(SchemaHighlightsShown.lines(of: card, maps: editor.proseMaps, sync: editor.schemaSync, resolve: { _ in .missing })[index].first)
    }

    /// The pointer moved to a point on the canvas, in view points.
    func move(to point: CGPoint) {
        editor.pointerMoved(PointerEvent(location: point, timestamp: 1, clickCount: 0))
    }

    /// The popover showing's text, once 500 ms have passed.
    func popoverAfterDelay() -> String? {
        scheduler.advance(by: .milliseconds(500))
        return editor.popover?.text.string
    }
}

/// Whether a pixel of the white card (0...255, as `pixel` reads it) is a field's pale blue.
private func isFieldTinted(_ pixel: [Int]) -> Bool { pixel[2] - pixel[0] >= 20 && pixel[0] <= 240 }

@MainActor let highlightShownTests = Suite("Schema highlights shown", [
    test("resting the pointer on a highlight's words on the card shows the part of the schema they say, as the panel colors JSON, below their line; other words show none") {
        let b = try HighlightBench()
        let id = b.jiraCard()
        let key = try b.line(of: "key", on: id)
        b.move(to: CGPoint(x: key.midX, y: key.midY))
        expectEqual(b.popoverAfterDelay(), "\"key\": {\n  \"type\": \"string\",\n  \"pattern\": \"^[A-Z][A-Z0-9]+-[0-9]+$\"\n}")
        expectEqual(b.editor.popover?.anchor, key, "beside the words' line")
        let text = try require(b.editor.popover?.text)
        expectEqual(text.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor, NSColor.systemBlue, "a member's name, as the panel's")
        expectEqual((text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch, true)
        let rule = try b.line(of: "one-line", on: id)
        b.move(to: CGPoint(x: rule.midX, y: rule.midY))
        expectEqual(b.editor.popover?.text.string, "\"maxLength\": 255", "at once: one was showing")
        let card = try require(b.card(id))
        b.move(to: CGPoint(x: card.frame.maxX - 4, y: card.frame.maxY - 4))        // the card, off its words
        expect(b.editor.popover == nil, "off them")
        let whole = try b.line(of: "jira ticket", on: id)
        b.move(to: CGPoint(x: whole.midX, y: whole.midY))
        expectEqual(b.editor.popover?.text.string, jiraSchema, "the root: the whole schema")
    },
    test("a card edited or drawn as a skeleton shows no popover on the canvas") {
        let b = try HighlightBench()
        let id = b.jiraCard()
        let key = try b.line(of: "key", on: id)
        expect(b.editor.beginEditing(id))
        b.move(to: CGPoint(x: key.midX, y: key.midY))
        expectEqual(b.popoverAfterDelay(), nil, "its editor has its own")
        b.editor.endEditing()
        b.editor.skeletonZoom = 2
        b.move(to: CGPoint(x: key.midX + 1, y: key.midY))
        expectEqual(b.popoverAfterDelay(), nil, "its words aren't drawn")
    },
    test("editing a card keeps its highlights, where the canvas draws them, under its text: pixel for pixel but anti-aliasing, at 1× and 2×, zoomed in and out") {
        for (scale, zoom) in [(1, 1), (2, 1), (1, 2), (2, 0.6)] as [(CGFloat, CGFloat)] {
            let b = try HighlightBench()
            b.editor.camera.setZoom(zoom, around: .zero)
            let id = b.jiraCard()
            let frame = try require(b.editor.document[id]?.box)
            let size = CGSize(width: (frame.maxX + 20) * zoom, height: (frame.maxY + 20) * zoom), inView = b.editor.camera.toView(frame)
            let drawn = renderBitmap(b.editor, size: size, scale: scale)
            let key = b.editor.camera.toView(try b.line(of: "key", on: id))
            expect(isFieldTinted(pixel(drawn, at: CGPoint(x: key.minX + 1, y: key.minY + 1), scale: scale)), "at \(scale)×, zoom \(zoom): drawn")
            expect(b.editor.beginEditing(id))
            let edited = renderBitmap(b.editor, size: size, scale: scale, editing: try require(b.editor.makeEditingView()))
            let difference = largestDifference(drawn, edited, in: inView, scale: scale)
            expect(difference <= antiAliasing, "at \(scale)×, zoom \(zoom): a pixel differs by \(difference)")
            b.editor.endEditing()
        }
    },
    test("in the editor, words kept as the description's typed keep their highlights; words typed over lose theirs") {
        let b = try HighlightBench()
        let id = b.jiraCard()
        let size = CGSize(width: 460, height: 260)
        let key = try b.line(of: "key", on: id), link = try b.line(of: "link to it", on: id)
        expect(b.editor.beginEditing(id))
        let editing = try require(b.editor.makeEditingView())
        let textView = try require(editing.firstResponder as? NSTextView)
        var shown = renderBitmap(b.editor, size: size, editing: editing)
        expect(isFieldTinted(pixel(shown, at: CGPoint(x: key.minX + 1, y: key.minY + 1))), "the caret placed: still there")
        let at = (textView.string as NSString).range(of: "link to it")
        textView.insertText("url", replacementRange: at)
        textView.insertText("Its ", replacementRange: NSRange(location: 0, length: 0))
        shown = renderBitmap(b.editor, size: size, editing: editing)
        expect(b.card(id)?.props.prompt.stored.hasPrefix("Its a jira ticket") == true)
        expect(!isFieldTinted(pixel(shown, at: CGPoint(x: link.minX + 1, y: link.minY + 1))), "typed over")
        let moved = try b.line(of: "key", on: id)
        expect(moved.minX > key.minX, "along with what's typed before it")
        expect(isFieldTinted(pixel(shown, at: CGPoint(x: moved.minX + 1, y: moved.minY + 1))), "kept, where it's gone")
    },
    test("in the editor, resting the pointer on a highlight's words shows their popover over the editor; typing takes it down") {
        let panel = try SchemaPanelWindow()
        ProseMapService.forgetEveryAnswer()
        SchemaHighlightsShown.forgetEverything()
        panel.model.fallback = { request in
            request.model == ProseMapPrompt.model ? .success(ModelResponse(text: jiraAnswer)) : .failure(.server(status: 0, message: "no"))
        }
        let id = panel.show(card(jiraSchema, prompt: jiraPrompt, at: CGPoint(x: 100, y: 100), width: 320))
        _ = renderBitmap(panel.editor, size: panel.canvas.frame.size)          // a frame draws it in full, which asks
        let maps = panel.editor.proseMaps, sync = panel.editor.schemaSync
        panel.window.spin { !SchemaHighlightsShown.placed(for: panel.editor.document[id]!.typed(as: SchemaCard.self)!, maps: maps, sync: sync).isEmpty }
        let card = try require(panel.editor.document[id]?.typed(as: SchemaCard.self))
        let placed = SchemaHighlightsShown.placed(for: card, maps: maps, sync: sync), text = card.props.prompt.stored as NSString
        let index = try require(placed.firstIndex { text.substring(with: $0.range) == "summary" })
        let summary = try require(SchemaHighlightsShown.lines(of: card, maps: maps, sync: sync, resolve: { _ in .missing })[index].first)
        let view = try panel.describe(id)
        panel.window.settle()
        let point = panel.canvas.convert(panel.editor.camera.toView(CGPoint(x: summary.midX, y: summary.midY)), to: nil)
        view.mouseMoved(with: panel.window.mouse(.mouseMoved, at: CGPoint(x: point.x, y: panel.window.contentView!.frame.height - point.y), time: 1))
        panel.window.spin { panel.editor.popover != nil }
        expectEqual(panel.editor.popover?.text.string, "\"summary\": {\n  \"type\": \"string\",\n  \"maxLength\": 255\n}")
        expect(panel.canvas.popoverView != nil && panel.canvas.subviews.last === panel.canvas.popoverView, "over the editor")
        panel.window.type("x")
        expect(panel.editor.popover == nil, "typing takes it down")
        expect(panel.canvas.popoverView == nil)
    },
])
