import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Geometry
import LanguageModels
import Mentions
import ProseMaps
import TestKit
import Types

// A type's highlights as a person meets them on the canvas: behind their words, and resting the
// pointer on them shows the part of the schema they say. (A note's editor, which shows them too, is
// StickyNotesTests'.)

extension HighlightBench {
    /// The owner's example, 320 wide at (100, 100), its highlights landed.
    func jiraType() -> ShapeID {
        let id = editor.addType(jiraSchema, words: jiraPrompt, at: CGPoint(x: 100, y: 100), width: 320)
        frame()
        settle()
        return id
    }

    /// Where the type's highlight of `words` is drawn, its first line, in world units.
    func line(of words: String, on id: ShapeID) throws -> CGRect {
        let text = try require(editor.words(id)).stored as NSString
        let placed = placed(id)
        let index = try require(placed.firstIndex { text.substring(with: $0.range) == words }, "no highlight of \(words)")
        return try require(lines(id)[index].first)
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

/// Whether a pixel of the white memo (0...255, as `pixel` reads it) is a field's pale blue.
private func isFieldTinted(_ pixel: [Int]) -> Bool { pixel[2] - pixel[0] >= 20 && pixel[0] <= 240 }

@MainActor let highlightShownTests = Suite("Type highlights shown", [
    test("a type's highlights are drawn behind their words by its kind's render; a shape that isn't a type has none") {
        let b = try HighlightBench()
        let id = b.jiraType()
        let key = try b.line(of: "key", on: id)
        let drawn = renderBitmap(b.editor, size: CGSize(width: 460, height: 260))
        expect(isFieldTinted(pixel(drawn, at: CGPoint(x: key.minX + 1, y: key.minY + 1))), "behind the field's words")
        b.editor.removeType(id)
        let plain = renderBitmap(b.editor, size: CGSize(width: 460, height: 260))
        expect(!isFieldTinted(pixel(plain, at: CGPoint(x: key.minX + 1, y: key.minY + 1))), "no longer a type")
    },
    test("resting the pointer on a highlight's words shows the part of the schema they say, as the panel colors JSON, below their line; other words show none") {
        let b = try HighlightBench()
        let id = b.jiraType()
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
        let frame = try require(b.editor.document[id]?.box)
        b.move(to: CGPoint(x: frame.maxX - 4, y: frame.maxY - 4))        // the type, off its words
        expect(b.editor.popover == nil, "off them")
        let whole = try b.line(of: "jira ticket", on: id)
        b.move(to: CGPoint(x: whole.midX, y: whole.midY))
        expectEqual(b.editor.popover?.text.string, jiraSchema, "the root: the whole schema")
    },
    test("a type drawn as a skeleton shows no popover") {
        let b = try HighlightBench()
        let id = b.jiraType()
        let key = try b.line(of: "key", on: id)
        b.editor.skeletonZoom = 2
        b.move(to: CGPoint(x: key.midX + 1, y: key.midY))
        expectEqual(b.popoverAfterDelay(), nil, "its words aren't drawn")
    },
])
