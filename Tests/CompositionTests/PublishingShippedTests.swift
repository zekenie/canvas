import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Clipboard
import HostSlots
import LanguageModels
import Locking
import Mentions
import Publishing
import Selection
import ShippedTesting
import StickyNotes
import TestKit

// Publishing as shipped: which kinds can be public, its chip beside the lock's, a copy, and a draw.

@MainActor private func emptyBoard(_ pasteboard: NSPasteboard = .withUniqueName()) -> EditorHarness {
    EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
}

@MainActor let publishingShippedTests = Suite("Publishing, as shipped", [
    test("every kind can be public but the arrow and the reference, whose definitions adopt NeverPublic; and every kind that can be is mentionable, so it can be picked") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for kind in registry.kinds {
            if kind == "arrow" || kind == "reference" {
                expect(!registry.canBePublic(kind), "nothing binds to an arrow, and a reference stands for what's public")
                expect(!registry.properties(for: kind).contains("public"))
            } else {
                expect(registry.canBePublic(kind), "\(kind) can be public")
                expect(registry.properties(for: kind).contains("public"), "\(kind) holds `public`")
                expect(registry.isMentionable(kind), "\(kind) is public by choice, so it must be one a picker can offer")
            }
        }
    },
    test("a public note's chip sits left of the lock's, 4 points apart, and Public is the text") {
        let h = emptyBoard()
        let note = h.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Pricing"))
        h.editor.makePublic([note])
        h.editor.lock([note])
        let frames = h.editor.adornmentFrames(of: note)
        let chip = try require(frames.first { $0.adornment == .of(PublicChip.self) })
        let lock = try require(frames.first { $0.adornment == .of(LockChip.self) })
        expectEqual(chip.label.text, "Public")
        expectEqual(chip.rect.maxX, lock.rect.minX - 4)
        expectEqual(lock.rect.maxX, 300)
    },
    test("a copy of a public note is public, pasted in place; the original keeps its chip") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let note = h.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Pricing"))
        h.editor.makePublic([note])
        h.editor.selection = note
        h.editor.copySelection()
        let before = h.editor.document
        h.editor.paste()
        let copy = try require(h.editor.shapes(since: before).first)
        expectEqual(copy[PublicProperty.self], true, "copies keep what a shape knows")
    },
    test("canvas draw: `public: true` makes a shape public, `public: false` takes it back, and the schema says so") {
        let h = emptyBoard()
        let commands = h.editor.registry.hostCommands
        let spec = try require(commands.specs.first { $0.name == "draw" })
        @MainActor func draw(_ script: String) throws {
            let params = try spec.params(from: ["-"], standardInput: { script })
            _ = try awaitResult { try await commands.run(spec.name, .object(params), h.editor) }
        }
        try draw(#"sticky-note "Pricing" text: "Plans" public: true"#)
        let note = try require(h.editor.document.shapes.first)
        expectEqual(note[PublicProperty.self], true)
        expectEqual(h.chipText(of: note.id), "Public")
        try draw(#"sticky-note "Pricing" public: false"#)
        expect(h.editor.document[note.id]?[PublicProperty.self] != true, "private: written as false, as locked: false is")
    },
])

extension EditorHarness {
    /// What a shape's public chip says as laid out now ("" for a symbol alone), nil without one.
    func chipText(of id: ShapeID) -> String? {
        editor.adornmentFrames(of: id).first { $0.adornment == .of(PublicChip.self) }.map { $0.label.text ?? "" }
    }
}
