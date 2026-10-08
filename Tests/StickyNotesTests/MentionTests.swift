import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import Foundation
import Mentions
import StickyNotes
import SwiftUI
import TableOfContents
import TestKit
import TextEditing
import Titles

// A note's text may mention shapes: its third version, its emptiness, its row, how it's mentioned,
// and its editor begun from a pill. Pills drawn against the editor's are the integrator's, once
// Mentions draws them.

private let groceriesID = ShapeID(UUID(uuidString: "7C1E0B8A-2F4D-4A6B-9C3E-5D2F1A0B9C8D")!)
private let frame = CGRect(x: 0, y: 0, width: 200, height: 200)

/// A note's props at version 2 (before its text could mention), `text` as written.
private func version2(_ text: String) throws -> Data {
    try JSONEncoder().encode(JSONValue.object(["frame": [[80, 80], [200, 200]], "text": .string(text)]))
}

@MainActor private func noteEditor(scheduler: any Scheduler = ManualScheduler()) throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: scheduler)
}

extension CanvasEditor {
    /// Inserts a note, titled `title` (nil: untitled), in a transaction of its own.
    @discardableResult
    fileprivate func addNote(_ text: MentionText = "", titled title: String? = nil, at origin: CGPoint = .zero, id: ShapeID = ShapeID()) -> ShapeID {
        var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: text))
        note[TitleProperty.self] = title
        transact { $0.insert(note) }
        return id
    }

    fileprivate func note(_ id: ShapeID) -> ShapeRecord<StickyNote>? { document[id]?.typed(as: StickyNote.self) }

    fileprivate func label(of id: ShapeID) -> MentionAppearance? { document[id].flatMap(registry.mentionAppearance) }
}

/// The table of contents alone in an unshown window, its editor on real time, so the list draws its
/// rows while the main run loop runs.
@MainActor
private final class ContentsList {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let hosting: NSView

    init(_ editor: CanvasEditor) {
        hosting = NSHostingView(rootView: TableOfContentsView(editor: editor, onExit: {}))
        hosting.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        window.contentView = hosting
        window.settle()
    }

    /// The list's rows, less its header.
    var rows: Int { max(0, (hosting.descendants(NSTableView.self).first?.numberOfRows ?? 0) - 1) }
}

@MainActor let noteMentionTests = Suite("Sticky note mentions", [
    test("the third version escapes text that would now read as a mention, byte for byte, so it reads as the text it was") {
        let codec = BoardCodec(registry: try Registry(plugins: notePlugins))
        let id = groceriesID.rawValue.uuidString
        let cases: [(old: String, stored: String)] = [
            ("Ask @[Groceries](shape:\(id)) first", "Ask \\@[Groceries](shape:\(id)) first"),
            ("Ask @[Groceries](shape:\(id.lowercased()))", "Ask \\@[Groceries](shape:\(id.lowercased()))"),
            ("Escaped \\@[x](shape:\(id))", "Escaped \\\\\\@[x](shape:\(id))"),
            ("C:\\\\@[", "C:\\\\\\\\\\@["),
            ("@[", "\\@["),
            ("a@b.c, @ [x], C:\\path, \\n", "a@b.c, @ [x], C:\\path, \\n"),
            ("Buy milk\nand bread", "Buy milk\nand bread"),
        ]
        for (old, stored) in cases {
            let note = try require(codec.decodeRecord(props: try version2(old), kind: StickyNote.kind, version: 2).typed(as: StickyNote.self))
            expectEqual(note.props.text.stored, stored, old.debugDescription)
            expectEqual(note.props.text.plainText(), old, "reads as the text it was: \(old.debugDescription)")
            expectEqual(note.props.text.mentioned, [], "mentions nothing: \(old.debugDescription)")
        }
    },
    test("the third version's step runs once: a board it read writes today's version, which reads back as it was, byte for byte") {
        let codec = BoardCodec(registry: try Registry(plugins: notePlugins))
        let old = "Ask @[Groceries](shape:\(groceriesID.rawValue.uuidString)) first, from C:\\@[x"
        let migrated = try codec.decodeRecord(props: try version2(old), kind: StickyNote.kind, version: 2)
        let saved = try codec.encode(CanvasDocument(shapes: [migrated]))
        let read = try codec.decode(saved).document
        expectEqual(read[migrated.id]?.typed(as: StickyNote.self)?.props.text, migrated.typed(as: StickyNote.self)?.props.text,
                    "not escaped again")
        expectEqual(try codec.encode(read), saved)
        expectEqual(codec.version(of: StickyNote.kind), 3)
    },
    test("a note whose text is only a mention is listed by it, whitespace around it or not; one of only whitespace is an Empty Note") {
        let editor = try noteEditor()
        let only = editor.addNote(MentionText([.mention(groceriesID, label: "Groceries")]))
        let spaced = editor.addNote(MentionText([.text(" \n"), .mention(groceriesID, label: "Groceries"), .text("  ")]), at: CGPoint(x: 300, y: 0))
        let blank = editor.addNote(MentionText(plain: " \n "), at: CGPoint(x: 600, y: 0))
        let contents = try require(editor.tableOfContents)
        @MainActor func row(_ id: ShapeID) -> String? { contents.entries.first { $0.id == id }?.label.map { $0.text.isEmpty ? $0.placeholder : $0.text } ?? nil }
        expectEqual(row(only), "@Groceries")
        expectEqual(row(spaced), "@Groceries")
        expectEqual(row(blank), "Empty Note")
    },
    test("a note is mentioned by its title, else its text's first line (each mention @…), else as an untitled note") {
        let editor = try noteEditor()
        let titled = editor.addNote("Buy milk", titled: "Groceries")
        let lined = editor.addNote("\n  Buy milk  \nand bread")
        let mentioning = editor.addNote(MentionText([.mention(titled, label: "Old name"), .text(" first\nthen more")]))
        let blank = editor.addNote(" ")
        expectEqual(editor.label(of: titled)?.label, "Groceries")
        expectEqual(editor.label(of: lined)?.label, "Buy milk")
        expectEqual(editor.label(of: mentioning)?.label, "@… first", "no other shape's name, live or held")
        let untitled = try require(editor.label(of: blank))
        expectEqual(untitled.label, "Untitled Note")
        expect(untitled.isPlaceholder)
        expectEqual(untitled.systemImage, "note.text", "the Note tool's")
        expectEqual(untitled.kindName, "Note")
        expectEqual(untitled.tint, .systemYellow, "in the @ picker and Mentioned In, a note's symbol is yellow, as in its row")
        let row = try require(editor.tableOfContents?.entries.first { $0.id == blank }?.label)
        expectEqual(row.color, Color(nsColor: .systemYellow))
        editor.transact { $0.update(blank, as: StickyNote.self) { $0.props.text = "Now it says something" } }
        expectEqual(editor.label(of: blank)?.label, "Now it says something")
        expectEqual(editor.mentions?.resolve(blank), .live(try require(editor.label(of: blank))))
    },
    test("its row shows each mention by its shape's name now, or by the name it holds where the shape isn't on the board") {
        let editor = try noteEditor()
        let groceries = editor.addNote("Milk", titled: "Groceries", id: groceriesID)
        let gone = ShapeID()
        let note = editor.addNote(MentionText([.text("Get "), .mention(groceries, label: "Shopping"), .text(" and "), .mention(gone, label: "Old list")]),
                                  at: CGPoint(x: 300, y: 0))
        let contents = try require(editor.tableOfContents)
        @MainActor func row(_ id: ShapeID) -> String? { contents.entries.first { $0.id == id }?.label?.text }
        expectEqual(row(note), "Get @Groceries and @Old list")
        editor.transact { $0.update(groceries) { $0[TitleProperty.self] = "Market" } }
        expectEqual(row(note), "Get @Market and @Old list", "a rename shows in the rows that mention it")
        editor.transact { $0.delete([groceries]) }
        expectEqual(row(note), "Get @Shopping and @Old list", "deleted: the name the mention holds")
        editor.undo()
        expectEqual(row(note), "Get @Market and @Old list", "the deletion undone, named as it is again")
        editor.undo()
        expectEqual(row(note), "Get @Groceries and @Old list", "the rename undone")
        editor.redo()
        editor.redo()
        expectEqual(row(note), "Get @Shopping and @Old list", "redone: deleted again")
        expectEqual(editor.note(note)?.props.text.stored,
                    MentionText([.text("Get "), .mention(groceries, label: "Shopping"), .text(" and "), .mention(gone, label: "Old list")]).stored,
                    "nothing written to the note")
    },
    test("renaming a mentioned note redraws its row and the rows of the notes that mention it, and no other") {
        let editor = try noteEditor(scheduler: TaskScheduler())
        let groceries = editor.addNote("Milk", titled: "Groceries")
        editor.addNote(MentionText([.text("Ask "), .mention(groceries, label: "Groceries")]), at: CGPoint(x: 300, y: 0))
        editor.addNote(MentionText([.mention(groceries, label: "Groceries"), .text(" today")]), at: CGPoint(x: 600, y: 0))
        editor.addNote("Mentions nothing", at: CGPoint(x: 900, y: 0))
        let other = editor.addNote("Other", titled: "Other", at: CGPoint(x: 1200, y: 0))
        let list = ContentsList(editor)
        list.window.spin { list.rows == 5 }
        list.window.settle()
        let contents = try require(editor.tableOfContents)
        @MainActor func redrawn(_ change: () -> Void) -> Int {
            let before = contents.rowsRedrawn
            change()
            list.window.spin { contents.rowsRedrawn > before }
            list.window.settle()
            return contents.rowsRedrawn - before
        }
        expectEqual(redrawn { editor.transact { $0.update(groceries) { $0[TitleProperty.self] = "Market" } } }, 3,
                    "the renamed note's row and the two that mention it")
        expectEqual(contents.entries.compactMap { $0.label?.text }, ["Market", "Ask @Market", "@Market today", "Mentions nothing", "Other"])
        expectEqual(redrawn { editor.transact { $0.update(other) { $0[TitleProperty.self] = "Else" } } }, 1, "a note nothing mentions: its own row")
        expectEqual(redrawn { editor.transact { $0.update(groceries, as: StickyNote.self) { $0.props.frame.origin.y += 40 } } }, 1,
                    "a move changes no name: its own row alone")
    },
    test("editing begun from a press on a pill selects the pill; on text, the caret goes there, or for a double-click the word; begun from nowhere, where it always has") {
        let editor = try noteEditor()
        editor.addNote("Milk", titled: "Groceries", id: groceriesID)
        let origin = CGPoint(x: 20, y: 300)
        let note = editor.addNote(MentionText([.text("See "), .mention(groceriesID, label: "Groceries"), .text(" soon")]), at: origin)
        @MainActor func textView(at point: CGPoint?, clickCount: Int = 1) throws -> MentionTextView<AnyMentionable> {
            editor.endEditing()
            expect(editor.beginEditing(note, at: point, clickCount: clickCount))
            return try require(editor.makeEditingView()?.firstResponder as? MentionTextView<AnyMentionable>)
        }
        let plain = try textView(at: nil)
        let caret = plain.selectedRange()
        // Where the pill is, in the note: its character's segment in the text view, whose
        // coordinates are the note's, in world units, from its top-left corner.
        let pill = try require(segment(of: NSRange(location: 4, length: 1), in: plain))
        expect(pill.width > 20, "a pill, not a caret's width: \(pill)")
        let onPill = CGPoint(x: origin.x + pill.midX, y: origin.y + pill.midY)
        expectEqual(try textView(at: onPill).selectedRange(), NSRange(location: 4, length: 1), "the pill's character")
        expectEqual(caret, NSRange(location: 10, length: 0), "from nowhere: at the end")
        let beforePill = try textView(at: CGPoint(x: origin.x + pill.minX - 12, y: origin.y + pill.midY)).selectedRange()
        expect(beforePill.length == 0 && (1...3).contains(beforePill.location), "on the text before it, between its characters there: \(beforePill)")
        expectEqual(try textView(at: CGPoint(x: origin.x + pill.minX - 12, y: origin.y + pill.midY), clickCount: 2).selectedRange(),
                    NSRange(location: 0, length: 3), "a double-click there: the word, See")
        expectEqual(try textView(at: CGPoint(x: origin.x + pill.maxX + 20, y: origin.y + pill.midY), clickCount: 2).selectedRange(),
                    NSRange(location: 6, length: 4), "and after the pill, soon")
        expectEqual(try textView(at: CGPoint(x: origin.x + pill.midX, y: origin.y + pill.midY), clickCount: 2).selectedRange(),
                    NSRange(location: 4, length: 1), "a double-click on the pill: the pill")
        expectEqual(try textView(at: CGPoint(x: origin.x + 100, y: origin.y + 180)).selectedRange(), caret, "below the text: its end")
        editor.endEditing()
        expectEqual(editor.note(note)?.props.text.stored,
                    MentionText([.text("See "), .mention(groceriesID, label: "Groceries"), .text(" soon")]).stored, "nothing written")
    },
    test("a note made from properties (the command line's draw) with mentions is as tall as its editor fits it: each pill measured live, by the name it holds; editing writes nothing") {
        let editor = try noteEditor()
        let targets = [("Groceries", groceriesID), ("Milk and eggs", ShapeID()), ("Q", ShapeID())]
        for (index, (title, id)) in targets.enumerated() {
            editor.addNote("", titled: title, at: CGPoint(x: 400 * CGFloat(index), y: -400), id: id)
        }
        let text = MentionText((0..<30).flatMap { index -> [MentionRun] in
            let (title, id) = targets[index % targets.count]
            return [.text(index == 0 ? "Ask " : index % 7 == 0 ? ",\nthen " : " and "), .mention(id, label: title)]
        } + [.text(" soon.")])
        for (index, width) in [200.0, 260, 360].enumerated() {
            let frame: JSONValue = [[.number(400 * Double(index)), 0], [.number(width), 200]]
            let made = try editor.registry.shape(StickyNote.kind, properties: ["frame": frame, "text": .string(text.stored)])
            editor.transact { $0.insert(made) }
            let inserted = editor.document[made.id]
            let height = try require(made.box?.height)
            expect(height > 200, "grown to its text: \(height)")
            expect(editor.beginEditing(made.id))
            _ = try require(editor.makeEditingView())
            expectEqual(editor.document[made.id]?.box?.height, height, "\(width) wide: the editor fits it as it was made")
            editor.endEditing()
            expectEqual(editor.document[made.id], inserted, "nothing written")
        }
    },
    test("typing beside a pill writes the text with its mention, named as its shape is now; a change that says the same writes nothing") {
        let counter = Contributor(id: "commit-counter") { $0.service { _ in CommitCounter() } }
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins + [counter]), scheduler: ManualScheduler())
        let commits = try require(editor.service(CommitCounter.self))
        editor.addNote("Milk", titled: "Groceries", id: groceriesID)
        let current = editor.addNote(MentionText([.text("See "), .mention(groceriesID, label: "Groceries")]), at: CGPoint(x: 300, y: 0))
        let stale = editor.addNote(MentionText([.text("See "), .mention(groceriesID, label: "Old name")]), at: CGPoint(x: 600, y: 0))
        @MainActor func edit(_ note: ShapeID) throws -> MentionTextView<AnyMentionable> {
            expect(editor.beginEditing(note))
            return try require(editor.makeEditingView()?.firstResponder as? MentionTextView<AnyMentionable>)
        }
        let before = commits.heard
        try edit(current).didChangeText()
        expectEqual(commits.heard, before, "the same text, its pill named as its shape is: no commit")

        let view = try edit(stale)
        view.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        expectEqual(commits.heard, before + 1)
        expectEqual(editor.note(stale)?.props.text, MentionText([.text("See "), .mention(groceriesID, label: "Groceries"), .text("!")]),
                    "the pill written with the name it shows")
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(editor.editingShapeID, nil, "Escape still ends editing")
    },
])

/// Counts the commits it hears.
@MainActor
private final class CommitCounter {
    var heard = 0
}

extension CommitCounter: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { heard += 1 }
}

/// Where a range of a text view's text is laid out, in the view's coordinates (TextKit 2).
@MainActor private func segment(of range: NSRange, in view: NSTextView) -> CGRect? {
    guard let layout = view.textLayoutManager, let content = layout.textContentManager,
          let start = content.location(content.documentRange.location, offsetBy: range.location),
          let end = content.location(start, offsetBy: range.length),
          let textRange = NSTextRange(location: start, end: end) else { return nil }
    layout.ensureLayout(for: textRange)
    var found: CGRect?
    layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
        found = frame
        return false
    }
    return found.map { $0.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y) }
}
