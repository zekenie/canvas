import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Clipboard
import LanguageModels
import Locking
import Mentions
import Publishing
import Selection
import ShippedTesting
import StickyNotes
import TestKit

// Publishing as shipped: which kinds can be private (every shape starts public), its chip beside the lock's, a copy, and
// a draw.

@MainActor private func emptyBoard(_ pasteboard: NSPasteboard = .withUniqueName()) -> EditorHarness {
    EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
}

@MainActor let publishingShippedTests = Suite("Publishing, as shipped", [
    test("every kind can be public but the arrow and the reference, whose definitions adopt NeverPublic; every other holds `private`, and is mentionable, so it can be picked") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for kind in registry.kinds {
            if kind == "arrow" || kind == "reference" {
                expect(!registry.canBePublic(kind), "nothing binds to an arrow, and a reference stands for what's public")
                expect(!registry.properties(for: kind).contains("private"))
            } else {
                expect(registry.canBePublic(kind), "\(kind) can be public")
                expect(registry.properties(for: kind).contains("private"), "\(kind) holds `private`")
                expect(registry.isMentionable(kind), "\(kind) is public until made private, so it must be one a picker can offer")
            }
        }
    },
    test("a new note is public and wears no chip; made private, its chip, the crossed eye alone, sits left of the lock's, 4 points apart") {
        let h = emptyBoard()
        let note = h.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Pricing"))
        expect(h.editor.document[note].map(h.editor.registry.isPublic) == true, "public, as every shape starts")
        expectEqual(h.chipSymbol(of: note), nil, "a public shape wears nothing")
        h.editor.makePrivate([note])
        h.editor.lock([note])
        let frames = h.editor.adornmentFrames(of: note)
        let chip = try require(frames.first { $0.adornment == .of(PrivateChip.self) })
        let lock = try require(frames.first { $0.adornment == .of(LockChip.self) })
        expectEqual(chip.label.text, nil, "a symbol alone, as the lock is")
        expectEqual(chip.label.systemImage, "eye.slash")
        expectEqual(chip.rect.maxX, lock.rect.minX - 4)
        expectEqual(lock.rect.maxX, 300)
    },
    test("a copy of a private note is private, pasted in place; the original keeps its chip") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let note = h.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Pricing"))
        h.editor.makePrivate([note])
        h.editor.selection = note
        h.editor.copySelection()
        let before = h.editor.document
        h.editor.paste()
        let copy = try require(h.editor.shapes(since: before).first)
        expectEqual(copy[PrivateProperty.self], true, "copies keep what a shape knows")
        expectEqual(h.chipSymbol(of: note), "eye.slash", "the original's crossed eye")
    },
    test("canvas draw: a note is drawn public, `private: true` makes it private, `private: false` takes that back") {
        let h = emptyBoard()
        let commands = h.editor.registry.hostCommands
        let spec = try require(commands.specs.first { $0.name == "draw" })
        @MainActor func draw(_ script: String) throws {
            let params = try spec.params(from: ["-"], standardInput: { script })
            _ = try awaitResult { try await commands.run(spec.name, .object(params), h.editor) }
        }
        try draw(#"sticky-note "Pricing" text: "Plans""#)
        let note = try require(h.editor.document.shapes.first)
        expectEqual(note[PrivateProperty.self], nil, "public, as every shape starts")
        expectEqual(h.chipSymbol(of: note.id), nil)
        try draw(#"sticky-note "Pricing" private: true"#)
        expectEqual(h.editor.document[note.id]?[PrivateProperty.self], true)
        expectEqual(h.chipSymbol(of: note.id), "eye.slash")
        try draw(#"sticky-note "Pricing" private: false"#)
        expect(h.editor.document[note.id].map(h.editor.registry.isPublic) == true, "public: written as false, as locked: false is")
        expectEqual(h.chipSymbol(of: note.id), "eye", "the open eye for a moment, as for any way a shape goes public")
    },
])

extension EditorHarness {
    /// The symbol a shape's private chip shows as laid out now (the crossed eye, or the open one fading), nil without one.
    func chipSymbol(of id: ShapeID) -> String? {
        editor.adornmentFrames(of: id).first { $0.adornment == .of(PrivateChip.self) }?.label.systemImage
    }
}
