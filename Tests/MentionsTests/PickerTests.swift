import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Mentions
import Selection
import TestKit
import Titles

// The `@` picker's model, headless: when an `@` opens it, what closes it, its rows (sections,
// ranking, exclusions, empty states), and its keys. The text view feeds it the text and the caret;
// here the tests do.

/// A board for the picker: the jot the text is on at the origin, plates near and far.
@MainActor
private func pickerBoard(_ more: [any CanvasPlugin] = [], _ build: (CanvasEditor) -> Void = { _ in }) throws -> (EditorHarness, ShapeID) {
    let h = try mentionHarness(more)
    let jot = h.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200)), titled: "Plan")
    build(h.editor)
    return (h, jot)
}

/// A picker for text on `owner`, its `@` at 0 and `query` typed after it.
@MainActor
private func picker(_ h: EditorHarness, owner: ShapeID?, query: String = "") -> MentionPicker {
    let picker = MentionPicker(at: 0, mentions: h.editor.mentionState, scope: AnyMentionable.self, owner: owner)
    let text = "@" + query
    expectEqual(picker.read(text as NSString, selection: NSRange(location: (text as NSString).length, length: 0), isEdit: true), nil)
    return picker
}

@MainActor private func ids(_ picker: MentionPicker) -> [ShapeID] { picker.rows.compactMap(\.candidate?.id) }

@MainActor let pickerTests = Suite("Picker", [
    test("an @ opens it at the start, after whitespace or a line break, or after an opening bracket or quote; never in a word") {
        let opening = ["@", " @", "a @", "a\n@", "a\t@", "(@", "[@", "{@", "\"@", "'@", "“@", "‘@", "a\u{00A0}@"]
        for text in opening {
            expect(MentionPicker.opens(in: text as NSString, at: (text as NSString).length - 1), "\(text.debugDescription) opens")
        }
        for text in ["name@", "a.@", "3@", ")@", "”@", "\u{FFFC}@"] {
            expect(!MentionPicker.opens(in: text as NSString, at: (text as NSString).length - 1), "\(text.debugDescription) doesn't")
        }
        expect(!MentionPicker.opens(in: "ab" as NSString, at: 1), "not an @")
        expect(!MentionPicker.opens(in: "@" as NSString, at: 1), "past the end")
    },

    test("the query is the text after the @ to the caret; each rule closes it") {
        let (h, jot) = try pickerBoard()
        let p = picker(h, owner: jot)
        expectEqual(p.read("@gro li" as NSString, selection: NSRange(location: 7, length: 0), isEdit: true), nil)
        expectEqual(p.query, "gro li")
        expectEqual(p.read("@gro li" as NSString, selection: NSRange(location: 4, length: 0), isEdit: false), nil, "back within it")
        expectEqual(p.query, "gro")
        expectEqual(p.read("@gro li" as NSString, selection: NSRange(location: 7, length: 0), isEdit: false), nil, "forward to its end")
        expectEqual(p.read("@gro li more" as NSString, selection: NSRange(location: 8, length: 0), isEdit: false), .caretLeft,
                    "past what was typed")
        expectEqual(p.read("@gro" as NSString, selection: NSRange(location: 0, length: 0), isEdit: false), .caretLeft, "before the @")
        expectEqual(p.read("@gro" as NSString, selection: NSRange(location: 1, length: 2), isEdit: false), .caretLeft, "a selection")
        expectEqual(p.read("gro" as NSString, selection: NSRange(location: 3, length: 0), isEdit: true), .atDeleted)
        expectEqual(p.read("" as NSString, selection: NSRange(location: 0, length: 0), isEdit: true), .atDeleted)
        expectEqual(p.read("@gro\n" as NSString, selection: NSRange(location: 5, length: 0), isEdit: true), .newline)
        expectEqual(p.read("@a\u{FFFC}" as NSString, selection: NSRange(location: 3, length: 0), isEdit: true), .caretLeft, "a pill in it")
        let limit = TitleProperty.maxLength
        let long = "@" + String(repeating: "g", count: limit)
        expectEqual(p.read(long as NSString, selection: NSRange(location: limit + 1, length: 0), isEdit: true), nil, "a whole title")
        expectEqual(p.read((long + "g") as NSString, selection: NSRange(location: limit + 2, length: 0), isEdit: true), .tooLong)
    },

    test("a query ending in a space closes it only when nothing matches") {
        let (h, jot) = try pickerBoard { editor in
            editor.add(Plate(CGRect(x: 300, y: 0, width: 100, height: 60)), titled: "Grocery List")
        }
        let p = picker(h, owner: jot)
        expectEqual(p.read("@grocery " as NSString, selection: NSRange(location: 9, length: 0), isEdit: true), nil)
        expectEqual(p.read("@qqqq " as NSString, selection: NSRange(location: 6, length: 0), isEdit: true), .spaceWithoutMatch)
    },

    test("an empty query lists Recent then Nearby, the first shape highlighted; the text's own shape isn't listed as nearby") {
        let (h, jot) = try pickerBoard { editor in
            editor.add(Plate(CGRect(x: 250, y: 0, width: 100, height: 60)), titled: "Near", id: idA)
            editor.add(Plate(CGRect(x: 5000, y: 0, width: 100, height: 60)), titled: "Far", id: idB)
            editor.add(Token(CGRect(x: 400, y: 0, width: 60, height: 60), caption: "Coin"), titled: nil, id: idC)
        }
        let fresh = picker(h, owner: jot)
        expectEqual(fresh.rows.first, .header("Nearby"))
        expectEqual(ids(fresh), [idA, idC, idB])
        expectEqual(fresh.highlighted, 1)
        expect(!ids(fresh).contains(jot))

        h.editor.mentionState.didPick(idB)
        let recent = picker(h, owner: jot)
        expectEqual(recent.rows.map { if case .header(let title) = $0 { title } else { nil } }.compactMap { $0 }, ["Recent", "Nearby"])
        expectEqual(recent.rows[1].candidate?.id, idB)
        expectEqual(recent.highlightedCandidate?.id, idB)
        expectEqual(ids(recent), [idB, idA, idC], "a recent pick isn't listed again as nearby")
    },

    test("the text's own shape can be mentioned: a typed query finds it, and so does its recent pick") {
        let (h, jot) = try pickerBoard { editor in
            editor.add(Plate(CGRect(x: 250, y: 0, width: 100, height: 60)), titled: "Planet", id: idA)
        }
        expectEqual(ids(picker(h, owner: jot, query: "plan")), [jot, idA], "\"Plan\" before \"Planet\"")
        h.editor.mentionState.didPick(jot)
        expectEqual(ids(picker(h, owner: jot)).first, jot, "recent")
    },

    test("a typed query lists the best matches, best first, and a changed query highlights its first row") {
        let (h, jot) = try pickerBoard { editor in
            editor.add(Plate(CGRect(x: 300, y: 0, width: 100, height: 60)), titled: "Grocery List", id: idA)
            editor.add(Plate(CGRect(x: 300, y: 0, width: 100, height: 60)), titled: "Groceries", id: idB)
            editor.add(Plate(CGRect(x: 300, y: 0, width: 100, height: 60)), titled: "Stone", id: idC)
        }
        let p = picker(h, owner: jot, query: "gro")
        expectEqual(ids(p), [idB, idA], "prefixes first, the shorter label breaking the tie; nothing that doesn't match")
        expectEqual(p.rows.first?.candidate?.matched, [0..<3])
        p.moveHighlight(by: 1)
        expectEqual(p.highlightedCandidate?.id, idA)
        _ = p.read("@groc" as NSString, selection: NSRange(location: 5, length: 0), isEdit: true)
        expectEqual(p.highlighted, 0, "the matches changed")
        _ = p.read("@groc" as NSString, selection: NSRange(location: 5, length: 0), isEdit: false)
        p.moveHighlight(by: 1)
        _ = p.read("@groc" as NSString, selection: NSRange(location: 5, length: 0), isEdit: false)
        expectEqual(p.highlighted, 1, "the same query keeps the highlight")
        let typo = picker(h, owner: jot, query: "grocey")
        expectEqual(ids(typo).first, idA, "one typo still finds it")
    },

    test("empty states are one row that can't be highlighted: No matches, Nothing to mention") {
        let (h, jot) = try pickerBoard()
        let nothing = picker(h, owner: jot)
        expectEqual(nothing.rows, [.empty("Nothing to mention")])
        expectEqual(nothing.highlighted, nil)
        let (b, owner) = try pickerBoard { editor in
            editor.add(Plate(CGRect(x: 300, y: 0, width: 100, height: 60)), titled: "Groceries")
        }
        let none = picker(b, owner: owner, query: "zebra")
        expectEqual(none.rows, [.empty("No matches")])
        expectEqual(none.highlighted, nil)
        none.moveHighlight(by: 1)
        none.highlight(row: 0)
        expectEqual(none.highlighted, nil)
        expectEqual(none.perform(#selector(NSResponder.insertNewline(_:))).taken, false, "Return does what it would without the picker")
        expectEqual(none.perform(#selector(NSResponder.insertTab(_:))).taken, false)
    },

    test("at most 50 shapes are listed, with no footer: the list scrolls") {
        let (h, jot) = try pickerBoard { editor in
            for i in 0..<60 { editor.add(Plate(CGRect(x: 300, y: CGFloat(i) * 80, width: 100, height: 60)), titled: "Shelf \(i)") }
        }
        let p = picker(h, owner: jot, query: "shelf")
        expectEqual(p.rows.count, 50)
        expect(p.rows.allSatisfy { $0.candidate != nil })
    },

    test("what's listed: shapes the text's scope admits, never shapes kept aside; read-only shapes too, marked") {
        let (h, jot) = try pickerBoard([FreezingPlugin()]) { editor in
            editor.add(Plate(CGRect(x: 300, y: 0, width: 100, height: 60)), titled: "Kiln", id: idA)
            editor.add(Token(CGRect(x: 300, y: 100, width: 60, height: 60), caption: "Kiln key"), titled: nil, id: idB)
            editor.add(Endpoint(CGRect(x: 300, y: 200, width: 160, height: 60), path: "Kiln status"), titled: nil, id: idC)
        }
        h.editor.transact { $0.update(idA) { $0[Frozen.self] = true } }
        let any = picker(h, owner: jot, query: "kiln")
        expectEqual(Set(ids(any)), [idA, idB, idC])
        expectEqual(any.rows.compactMap(\.candidate).first { $0.id == idA }?.isReadOnly, true)
        expectEqual(any.rows.compactMap(\.candidate).first { $0.id == idB }?.isReadOnly, false)

        let plates = MentionPicker(at: 0, mentions: h.editor.mentionState, scope: Only<Plate>.self, owner: jot)
        _ = plates.read("@kiln" as NSString, selection: NSRange(location: 5, length: 0), isEdit: true)
        expectEqual(ids(plates), [idA])
        let blockers = MentionPicker(at: 0, mentions: h.editor.mentionState, scope: Blockers.self, owner: jot)
        _ = blockers.read("@kiln" as NSString, selection: NSRange(location: 5, length: 0), isEdit: true)
        expectEqual(Set(ids(blockers)), [idA, idB])

        let aside = try keptAside(Plate.kind, id: ShapeID(), in: h.editor.registry)
        append([aside], to: h.editor)
        let after = picker(h, owner: jot, query: "")
        expect(!ids(after).contains(aside.id))
    },

    test("keys: ↑ and ↓ wrap, pages move eight and stop at the ends, Return and Tab pick, Escape and ⌥⎋ close, others pass") {
        let (h, jot) = try pickerBoard { editor in
            for i in 0..<12 { editor.add(Plate(CGRect(x: 300, y: CGFloat(i) * 80, width: 100, height: 60)), titled: "Shelf \(i)") }
        }
        let p = picker(h, owner: jot, query: "shelf")
        let all = ids(p)
        @MainActor func key(_ selector: Selector) -> (Bool, MentionPicker.Action?) {
            let result = p.perform(selector)
            return (result.taken, result.action)
        }
        expect(key(#selector(NSResponder.moveUp(_:))) == (true, nil))
        expectEqual(p.highlightedCandidate?.id, all[11])
        _ = key(#selector(NSResponder.moveDown(_:)))
        expectEqual(p.highlightedCandidate?.id, all[0])
        _ = key(#selector(NSResponder.scrollPageDown(_:)))
        expectEqual(p.highlightedCandidate?.id, all[8])
        _ = key(#selector(NSResponder.pageDown(_:)))
        expectEqual(p.highlightedCandidate?.id, all[11])
        _ = key(#selector(NSResponder.scrollPageUp(_:)))
        expectEqual(p.highlightedCandidate?.id, all[3])
        _ = key(#selector(NSResponder.pageUp(_:)))
        expectEqual(p.highlightedCandidate?.id, all[0])
        expect(key(#selector(NSResponder.insertNewline(_:))) == (true, .pick))
        expect(key(#selector(NSResponder.insertTab(_:))) == (true, .pick))
        expect(key(#selector(NSResponder.cancelOperation(_:))) == (true, .close))
        expect(key(#selector(NSResponder.complete(_:))) == (true, .close))
        expect(key(#selector(NSResponder.moveLeft(_:))) == (false, nil))
        expect(key(#selector(NSResponder.deleteBackward(_:))) == (false, nil))
    },

    test("the mouse highlights shapes' rows only, and a changed highlight tells the view") {
        let (h, jot) = try pickerBoard { editor in
            editor.add(Plate(CGRect(x: 300, y: 0, width: 100, height: 60)), titled: "Near", id: idA)
            editor.add(Plate(CGRect(x: 600, y: 0, width: 100, height: 60)), titled: "Far", id: idB)
        }
        let p = picker(h, owner: jot)
        expectEqual(p.rows.count, 3)
        p.highlight(row: 0)
        expectEqual(p.highlighted, 1, "a header isn't highlighted")
        p.highlight(row: 2)
        expectEqual(p.highlightedCandidate?.id, idB)
        p.highlight(row: 7)
        expectEqual(p.highlighted, 2)
    },

    test("a pick is followed by a space, but for whitespace or closing punctuation") {
        expect(MentionPicker.spaceAfterPick(before: nil))
        for character in "a1@(“‘-" { expect(MentionPicker.spaceAfterPick(before: String(character).utf16.first), "before \(character)") }
        for character in " \t\n.,;:!?)]}”’'\"" {
            expect(!MentionPicker.spaceAfterPick(before: String(character).utf16.first), "before \(character.debugDescription)")
        }
    },
])
