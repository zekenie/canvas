import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Mentions
import References
import TestKit
import TextEditing
import Titles

// The list over a pill's field, headless: what it offers for what's typed (the public shapes of the
// file, ranked as the `@` picker ranks them), the words row last, the hand-off once only the words
// row is left, the state row for an empty file, how each row says what it is, and the keys.

@MainActor private func picker(_ h: EditorHarness, text: String = "", owner: ShapeID? = nil) throws -> ReferencePicker {
    ReferencePicker(state: try require(h.editor.references), owner: owner, text: text)
}

/// The shapes a picker's rows name, by label, in order.
@MainActor private func labels(_ picker: ReferencePicker) -> [String] {
    picker.rows.compactMap { row in
        if case .shape(let choice) = row { choice.candidate.appearance.label } else { nil }
    }
}

@MainActor let pickerTests = Suite("The list over a pill's field", [
    test("with no public shape in the file and nothing typed, one dimmed state row says so, never a blank list; nothing can be picked") {
        let h = try referenceHarness()
        h.addBox("private plans", public: false)
        let picker = try picker(h)
        expectEqual(picker.rows, [.empty("No public shapes")])
        expectEqual(picker.list.rows, [.empty("No public shapes")])
        expectEqual(picker.highlighted, nil)
        expect(!picker.isHandoff)
        expectEqual(picker.perform(#selector(NSResponder.insertNewline(_:))).taken, false, "Return has nothing to pick")
    },

    test("with text and no public shape, only the words row is left, highlighted: the hand-off to natural language") {
        let h = try referenceHarness()
        let picker = try picker(h, text: "stuff about launch")
        expectEqual(picker.rows, [.words("stuff about launch")])
        expect(picker.isHandoff)
        expectEqual(picker.highlighted, 0)
        let item = try require(picker.list.rows.first?.item)
        expectEqual(item.title, "stuff about launch", "the text verbatim")
        expectEqual(item.symbol, "magnifyingglass")
        expectEqual(item.detail, nil)
        expect(!item.separated, "nothing above it to set it off from")
        expectEqual(picker.perform(#selector(NSResponder.insertNewline(_:))).action, .pick)
    },

    test("nothing typed lists the public shapes, with no headers and no words row; private ones and shapes with no name aren't offered") {
        let h = try referenceHarness()
        h.addBox("Pricing", public: true, at: CGRect(x: 100, y: 100, width: 100, height: 100))
        h.addBox("Plans", public: true, at: CGRect(x: 300, y: 100, width: 100, height: 100))
        h.addBox("Draft", public: false, at: CGRect(x: 500, y: 100, width: 100, height: 100))
        h.addTile(nil, public: true)
        let picker = try picker(h)
        expectEqual(Set(labels(picker)), ["Pricing", "Plans"], "the unnamed tile and the private box are left out")
        expectEqual(picker.list.rows.count, 2, "no headers, no words row")
        expect(picker.rows.allSatisfy { if case .shape = $0 { true } else { false } })
        expectEqual(picker.highlighted, 0, "the first shape is highlighted")
    },

    test("typing ranks the public shapes by what's typed, matched characters marked, and the words row is last, set off by a line, while shapes are listed") {
        let h = try referenceHarness()
        h.addBox("Pricing and plans", at: CGRect(x: 100, y: 100, width: 100, height: 100))
        h.addBox("Plan B", at: CGRect(x: 300, y: 100, width: 100, height: 100))
        h.addBox("Roadmap", at: CGRect(x: 500, y: 100, width: 100, height: 100))
        h.addBox("Plans in private", public: false, at: CGRect(x: 700, y: 100, width: 100, height: 100))
        let picker = try picker(h, text: "plan")
        expectEqual(labels(picker).first, "Plan B", "a prefix first")
        expectEqual(Set(labels(picker)), ["Plan B", "Pricing and plans"], "no private shape, no shape it doesn't match")
        expectEqual(picker.rows.last, .words("plan"), "the words row is last")
        let items = picker.list.rows.compactMap(\.item)
        expectEqual(items.last?.title, "plan")
        expectEqual(items.last?.symbol, "magnifyingglass")
        expect(items.last?.separated == true, "a line sets it off from the shapes")
        expect(items.dropLast().allSatisfy { !$0.separated })
        expectEqual(picker.highlighted, 0, "the first shape is highlighted, not the words")
        expect(!picker.isHandoff)
        expect(items[0].matched.isEmpty == false, "the characters it matched")
        expectEqual(items[0].symbol, "shippingbox")
        expect(items[0].tint != nil, "in its kind's tint")
        // Typing on narrows it to the hand-off.
        picker.setText("plan zzz")
        expect(picker.isHandoff)
        expectEqual(picker.highlighted, 0)
        picker.setText("")
        expectEqual(picker.rows.count, 3, "emptied, the shapes again and no words row")
        picker.setText("   ")
        expectEqual(picker.rows.count, 3, "white space isn't text")
    },

    test("each change is heard once, with the rows and highlight it left") {
        let h = try referenceHarness()
        h.addBox("Pricing", at: CGRect(x: 100, y: 100, width: 100, height: 100))
        let picker = try picker(h)
        var heard = 0
        picker.onChange = { heard += 1 }
        picker.setText("pri")
        expectEqual(heard, 1)
        picker.highlight(row: 1)
        expectEqual(heard, 2)
        expectEqual(picker.highlightedRow, .words("pri"))
    },

    test("a row says the board its shape is on when that isn't the board shown, and nothing when it is") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        var pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 400, width: 100, height: 100)))
        pocket[TitleProperty.self] = "Drawer"
        h.editor.transact { $0.insert(pocket) }
        expect(h.enter(pocket.id))
        h.addBox("Inside plans", at: CGRect(x: 100, y: 100, width: 100, height: 100))
        expect(h.editor.showBoard(.root))
        h.addBox("Outside plans", at: CGRect(x: 100, y: 100, width: 100, height: 100))
        let picker = try picker(h, text: "plans")
        let details = Dictionary(uniqueKeysWithValues: picker.list.rows.compactMap(\.item).filter { $0.symbol != "magnifyingglass" }.map { ($0.title, $0.detail) })
        expectEqual(details["Inside plans"] ?? "none", "Drawer", "on another board: its name")
        expectEqual(details["Outside plans"] ?? "none", nil, "on the board shown: none")
    },

    test("two rows called alike say their kind, and the board's name when it isn't the one shown: \"Kind · Board\"") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        var pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 400, width: 100, height: 100)))
        pocket[TitleProperty.self] = "Drawer"
        h.editor.transact { $0.insert(pocket) }
        expect(h.enter(pocket.id))
        h.addBox("Plan", at: CGRect(x: 100, y: 100, width: 100, height: 100))
        expect(h.editor.showBoard(.root))
        h.addBox("Plan", at: CGRect(x: 100, y: 100, width: 100, height: 100))
        h.addBox("Other", at: CGRect(x: 300, y: 100, width: 100, height: 100))
        let picker = try picker(h, text: "plan")
        let kind = try require(picker.rows.compactMap { row -> String? in
            if case .shape(let choice) = row { choice.candidate.appearance.kindName } else { nil }
        }.first)
        let details = Set(picker.list.rows.compactMap(\.item).filter { $0.title == "Plan" }.map { $0.detail ?? "none" })
        expectEqual(details, [kind, kind + " · Drawer"], "the one on the board shown says its kind alone")
        // A row that's alone in its name keeps just its board.
        picker.setText("other")
        expectEqual(picker.list.rows.compactMap(\.item).first?.detail, nil)
    },

    test("the keys: ↑ and ↓ move through the shapes and the words row, wrapping; Return and Tab pick the highlighted row; Escape closes; the rest are the text's") {
        let h = try referenceHarness()
        h.addBox("Plan A", at: CGRect(x: 100, y: 100, width: 100, height: 100))
        h.addBox("Plan B", at: CGRect(x: 300, y: 100, width: 100, height: 100))
        let picker = try picker(h, text: "plan")
        expectEqual(picker.rows.count, 3)
        let first = try require(picker.highlighted)
        _ = picker.perform(#selector(NSResponder.moveDown(_:)))
        expectEqual(picker.highlighted, first + 1)
        _ = picker.perform(#selector(NSResponder.moveDown(_:)))
        expectEqual(picker.highlightedRow, .words("plan"), "the words row, last")
        _ = picker.perform(#selector(NSResponder.moveDown(_:)))
        expectEqual(picker.highlighted, first, "↓ wraps to the first")
        _ = picker.perform(#selector(NSResponder.moveUp(_:)))
        expectEqual(picker.highlightedRow, .words("plan"), "↑ wraps to the last")
        expectEqual(picker.perform(#selector(NSResponder.insertNewline(_:))).action, .pick)
        expectEqual(picker.perform(#selector(NSResponder.insertTab(_:))).action, .pick)
        expectEqual(picker.perform(#selector(NSResponder.cancelOperation(_:))).action, .close)
        expectEqual(picker.perform(#selector(NSResponder.moveLeft(_:))).taken, false)
    },

    test("recent picks come first for nothing typed") {
        let h = try referenceHarness()
        h.addBox("Pricing", at: CGRect(x: 100, y: 100, width: 100, height: 100))
        let recent = h.addBox("Roadmap", at: CGRect(x: 700, y: 600, width: 100, height: 100))
        h.editor.mentions?.didPick(recent)
        let picker = try picker(h)
        expectEqual(labels(picker).first, "Roadmap")
    },

    test("public shapes on other boards are listed for nothing typed, however far from the board shown, so the list isn't empty while one can be picked") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        var pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 400, width: 100, height: 100)))
        pocket[TitleProperty.self] = "Drawer"
        h.editor.transact { $0.insert(pocket) }
        expect(h.enter(pocket.id))
        h.addBox("Deep plans", at: CGRect(x: 100, y: 100, width: 100, height: 100))
        expect(h.editor.showBoard(.root))
        let picker = try picker(h)
        expectEqual(Set(labels(picker)), ["Deep plans"])
        expect(picker.rows != [.empty("No public shapes")])
    },
])
