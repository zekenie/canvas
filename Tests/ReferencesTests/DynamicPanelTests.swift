import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import Publishing
import QueryTranslation
import References
import Selection
import SwiftUI
import TableOfContents
import TestKit
import Titles

// A dynamic reference's panel, row and menu: the header says how many it found ("First of 7",
// "12 matches", "73 matches", "No matches", "Not public"; nothing while it's looked for); the Query
// section has the query, a status line only when there's something to say (what it found that isn't
// public, with Make Public, among it), and Match ☐ All; the Matches section, while
// it found shapes, a row each (the board's name where that isn't the board shown, the rows All would
// add dimmed), "and 42 more" past eight. The row in the table of contents counts an All one's
// matches; the menu shows every match and switches All. Layouts headless, then the panel in a window.

@MainActor private func layout(_ h: EditorHarness, _ id: ShapeID) throws -> DetailLayout {
    try require(h.editor.detailPanel).layout(for: try require(h.editor.document[id]))
}

@MainActor private func header(_ h: EditorHarness, _ id: ShapeID) throws -> ReferenceHeaderContent {
    try require(try layout(h, id).header(as: ReferenceHeader.self)).content
}

@MainActor private func sections(_ h: EditorHarness, _ id: ShapeID) throws -> [String] {
    let shown = try layout(h, id)
    guard let tab = shown.tabs.first else { return [] }
    return shown.sections(in: tab).map(\.section)
}

/// `count` public boxes titled "B0", "B1", …, in rows far below the view.
@MainActor @discardableResult private func boxes(_ h: EditorHarness, _ count: Int) -> [ShapeID] {
    var ids: [ShapeID] = []
    for index in 0..<count {
        ids.append(h.addBox("B\(index)", at: CGRect(x: CGFloat(index % 20) * 60, y: 2_000 + CGFloat(index / 20) * 60, width: 50, height: 50)))
    }
    return ids
}

@MainActor let dynamicPanelTests = Suite("A dynamic reference's panel, row and menu", [
    test("the header says how many it found: First of 7, 12 matches, 73 matches, 1 match, No matches; nothing while it's looked for") {
        let h = try referenceHarness()
        boxes(h, 73)
        let first = h.addReference(words: "the boxes", query: "box")
        let some = h.addReference(words: "a dozen", query: "box[title^=\"B1\"]", all: true, at: CGPoint(x: 400, y: 400))
        let many = h.addReference(query: "box", all: true, at: CGPoint(x: 400, y: 500))
        let one = h.addReference(query: "\"B7\"", at: CGPoint(x: 400, y: 600))
        let none = h.addReference(words: "the tiles", query: "tile", at: CGPoint(x: 400, y: 700))
        expectEqual(try header(h, first), ReferenceHeaderContent(symbol: "magnifyingglass", title: "the boxes", subtitle: nil), "being looked for")
        h.answer()
        expectEqual(try header(h, first), ReferenceHeaderContent(symbol: "magnifyingglass", title: "the boxes", subtitle: "First of 73"))
        expectEqual(try header(h, some).subtitle, "11 matches", "B1 and B10 to B19")
        expectEqual(try header(h, many), ReferenceHeaderContent(symbol: "magnifyingglass", title: "box", subtitle: "73 matches"), "an agent's, called by its query")
        expectEqual(try header(h, one).subtitle, "1 match")
        expectEqual(try header(h, none).subtitle, "No matches")
        let refused = h.addReference(words: "nobody", query: "\"Nobody\"", at: CGPoint(x: 400, y: 800))
        h.answer()
        expectEqual(try header(h, refused).subtitle, "No matches", "a refusal finds nothing; the status line says why")
    },
    test("the Query section always, the Matches section only while it found shapes") {
        let h = try referenceHarness()
        boxes(h, 3)
        let found = h.addReference(query: "box")
        let none = h.addReference(query: "tile", at: CGPoint(x: 400, y: 400))
        let words = h.addReference(words: "blocked work", at: CGPoint(x: 400, y: 500))
        expectEqual(try sections(h, found), ["reference.query"], "not yet")
        h.answer()
        expectEqual(try sections(h, found), ["reference.query", "reference.matches"])
        expectEqual(try sections(h, none), ["reference.query"], "no matches: the header says so")
        expectEqual(try sections(h, words), ["reference.query"])
    },
    test("the Query section: the query, and a line only when there's something to say") {
        let h = try referenceHarness()
        boxes(h, 3)
        let state = try require(h.editor.references)
        let found = h.addReference(words: "the boxes", query: "box")
        let refused = h.addReference(words: "nobody", query: "\"Nobody\"", at: CGPoint(x: 400, y: 400))
        let words = h.addReference(words: "blocked work", at: CGPoint(x: 400, y: 500))
        h.answer()
        expectEqual(state.queryContent(of: try require(h.reference(found)), id: found), ReferenceQueryContent(query: "box", status: nil))
        let refusal = state.queryContent(of: try require(h.reference(refused)), id: refused)
        expectEqual(refusal.query, "\"Nobody\"")
        expect(refusal.status?.isWarning == true && refusal.status?.text.contains("Nobody") == true, "\(String(describing: refusal.status))")
        expectEqual(state.queryContent(of: try require(h.reference(words)), id: words), ReferenceQueryContent(query: nil, status: nil),
                    "not interpreted: no query, nothing to say")
    },
    test("the Matches section: a row each, the board's name where it isn't the board shown, the rows All would add dimmed, and how many more past eight") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        let ids = boxes(h, 10)
        var pocket = ShapeRecord(Pocket(CGRect(x: 1_400, y: 2_000, width: 100, height: 100)))
        pocket[TitleProperty.self] = "Drawer"
        h.editor.transact { $0.insert(pocket) }
        expect(h.enter(pocket.id))
        let inside = h.addBox("Z inside")
        expect(h.editor.showBoard(.root))
        let first = h.addReference(query: "box")
        let all = h.addReference(query: "box", all: true, at: CGPoint(x: 400, y: 400))
        h.answer()
        let state = try require(h.editor.references)
        let (rows, more) = state.matchRows(of: first)
        expectEqual(rows.map(\.id), Array(ids.prefix(8)))
        expectEqual(more, 3, "eleven in all")
        expectEqual(rows.map(\.dimmed), [false] + Array(repeating: true, count: 7), "what All would add, dimmed")
        expectEqual(rows.first?.name, "B0")
        expectEqual(rows.first?.symbol, "shippingbox")
        expectEqual(rows.first?.place, nil, "on the board shown")
        let (allRows, allMore) = state.matchRows(of: all)
        expect(allRows.allSatisfy { !$0.dimmed }, "every one stood for")
        expectEqual(allMore, 3)
        let everything = h.addReference(query: "box[title^=\"Z\"]", all: true, at: CGPoint(x: 400, y: 500))
        h.answer()
        expectEqual(state.matchRows(of: everything).rows.map(\.place), ["Drawer"], "another board's name")
        expectEqual(state.matchRows(of: everything).rows.map(\.id), [inside])
    },
    test("Match ☐ All in the window: the box in the control column after Match; what it writes is a step of its own; a match followed is gone to") {
        let h = try referenceHarness()
        let ids = boxes(h, 3)
        let id = h.addReference(query: "box")
        h.answer()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: DetailPanelView(editor: h.editor, onExit: {}))
        hosting.frame = CGRect(x: 0, y: 0, width: DetailStyle.idealWidth, height: 600)
        window.contentView = hosting
        h.editor.selectedShapeIDs = [id]
        // The checkbox: in the control column, after the 72 point label column and its spacing (16 + 72 + 8).
        let checkboxes = { hosting.descendants(NSButton.self).filter { !($0 is NSPopUpButton) && abs($0.convert($0.bounds, to: hosting).minX - 96) < 2 } }
        window.spin { checkboxes().count == 1 }
        let checkbox = try require(checkboxes().first)
        expect(checkbox.convert(checkbox.bounds, to: hosting).minY > 44, "under the header")
        // (A synthesized click on a SwiftUI toggle in an unshown window doesn't reach its binding: what it writes is `setAll`.)
        try require(h.editor.references).setAll(true, of: id)
        expectEqual(h.reference(id)?.all, true)
        expectEqual(h.editor.undoHistory.undoName, "Match All")
        h.answer()
        expectEqual(h.standsFor(id), ids)
        window.contentView = nil
        try require(h.editor.references).follow(match: ids[2])
        h.wait(1)
        expectEqual(h.editor.selectedShapeIDs, [ids[2]])
    },
    test("the menu: Show Matches goes to them, dimmed with none; Match All and Match First switch, each a step") {
        let h = try referenceHarness()
        let ids = boxes(h, 3)
        let id = h.addReference(query: "box")
        let none = h.addReference(query: "tile", at: CGPoint(x: 400, y: 500))
        h.answer()
        let frame = try require(h.editor.document[id]?.box)
        let menu = try require(h.secondaryClick(at: h.view(CGPoint(x: frame.midX, y: frame.midY))))
        expect(menu.outline.contains("Show Matches"), "\(menu.outline)")
        expect(menu.outline.contains("Match All") && !menu.outline.contains("Match First"), "\(menu.outline)")
        expect(!menu.outline.contains("Go to Original") && !menu.outline.contains("(Go to Original)"), "a query has no original: \(menu.outline)")
        try menu.choose("Match All")
        expectEqual(h.reference(id)?.all, true)
        expectEqual(h.editor.undoHistory.undoName, "Match All")
        h.answer()
        let again = try require(h.secondaryClick(at: h.view(CGPoint(x: frame.midX, y: frame.midY))))
        expect(again.outline.contains("Match First") && !again.outline.contains("Match All"), "\(again.outline)")
        try again.choose("Show Matches")
        h.wait(1)
        expectEqual(Set(h.editor.selectedShapeIDs), Set(ids), "its matches, selected")
        let noneFrame = try require(h.editor.document[none]?.box)
        let dimmed = try require(h.secondaryClick(at: h.view(CGPoint(x: noneFrame.midX, y: noneFrame.midY))))
        expect(dimmed.outline.contains("(Show Matches)"), "dimmed with none: \(dimmed.outline)")
    },
    test("Show Matches selects every match the header counts: the eleven of a first-match pill, given eight, and an All one's sixty") {
        let h = try referenceHarness()
        let ids = boxes(h, 60)
        let first = h.addReference(query: "box[title^=\"B1\"]")
        let all = h.addReference(query: "box", all: true, at: CGPoint(x: 400, y: 400))
        h.answer()
        expectEqual(try header(h, first).subtitle, "First of 11")
        expectEqual(try header(h, all).subtitle, "60 matches")
        for (id, expected) in [(first, Set([ids[1]] + ids[10...19])), (all, Set(ids))] {
            let frame = try require(h.editor.document[id]?.box)
            try require(h.secondaryClick(at: h.view(CGPoint(x: frame.midX, y: frame.midY)))).choose("Show Matches")
            // The All one holds every match: gone to a turn later, with no question asked.
            _ = spinRunLoop(until: { h.wait(0); return h.editor.selectedShapeIDs.count > 1 })
            expectEqual(Set(h.editor.selectedShapeIDs), expected, "every one, not only those it was given")
        }
    },
    test("what it found that isn't public: the header says Not public when none is, the Query section how many, with Make Public, beside the count when some are") {
        let h = try referenceHarness()
        let state = try require(h.editor.references)
        boxes(h, 3)
        for index in 0..<2 { h.addBox("P\(index)", public: false, at: CGRect(x: CGFloat(index) * 60, y: 2_200, width: 50, height: 50)) }
        let some = h.addReference(words: "the boxes", query: "box", all: true)
        let none = h.addReference(words: "the hidden", query: "box[title^=\"P\"]", at: CGPoint(x: 400, y: 400))
        h.answer()
        let line = ReferenceStatusLine(text: "2 not public", isWarning: false, isBusy: false, action: .makePublic)
        expectEqual(try header(h, some).subtitle, "3 matches", "the public ones")
        expectEqual(state.queryContent(of: try require(h.reference(some)), id: some).status, line)
        expectEqual(try header(h, none), ReferenceHeaderContent(symbol: "magnifyingglass", title: "the hidden", subtitle: "Not public"))
        expectEqual(state.queryContent(of: try require(h.reference(none)), id: none).status, line)
        expectEqual(try sections(h, none), ["reference.query"], "nothing it stands for to list")
        let row = try require(try require(try require(h.editor.tableOfContents).entries.first { $0.id == none }).label)
        expect(row.isPlaceholder, "it stands for nothing: dimmed, as one that found nothing")
    },
    test("Make Public makes every match that isn't public so, on whichever board it is, in one step; the pill stands for them once its wait ends; undo takes it back") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        let out = h.addBox("Out", public: false, at: CGRect(x: 100, y: 2_000, width: 50, height: 50))
        var pocket = ShapeRecord(Pocket(CGRect(x: 1_400, y: 2_000, width: 100, height: 100)))
        pocket[TitleProperty.self] = "Drawer"
        h.editor.transact { $0.insert(pocket) }
        expect(h.enter(pocket.id))
        let inside = h.addBox("In", public: false)
        expect(h.editor.showBoard(.root))
        let id = h.addReference(query: "box", all: true)
        h.answer()
        expectEqual(h.state(of: id), .privateMatches(text: "box", count: 2))
        try require(h.editor.references).makeMatchesPublic(of: id)
        _ = spinRunLoop(until: { h.editor.shape(inFile: inside)?[PrivateProperty.self] == nil })
        expectEqual(h.editor.document[out]?[PrivateProperty.self], nil)
        expectEqual(h.editor.undoHistory.undoName, "Make Public")
        h.answer(after: 250)
        expectEqual(Set(h.standsFor(id)), [out, inside], "on both boards")
        h.editor.undo()
        expectEqual(h.editor.shape(inFile: inside)?[PrivateProperty.self], true, "one step: both private again")
        expectEqual(h.editor.document[out]?[PrivateProperty.self], true)
        h.answer(after: 250)
        expectEqual(h.state(of: id), .privateMatches(text: "box", count: 2))
    },
    test("the leading magnifier goes to what it stands for: the first match as a mention's, every match by going to them") {
        let h = try referenceHarness()
        let ids = boxes(h, 3)
        let first = h.addReference(query: "box")
        h.answer()
        let frame = try require(h.editor.document[first]?.box)
        h.click(at: h.view(CGPoint(x: frame.minX + 18, y: frame.midY)))
        h.wait(1)
        expectEqual(h.editor.selectedShapeIDs, [ids[0]], "the first, as the pill stands for it")
    },
    test("the table of contents: words and a magnifier, an All one's count, what found nothing dimmed; an answer arriving remakes the row") {
        let h = try referenceHarness()
        boxes(h, 3)
        let all = h.addReference(words: "the boxes", query: "box", all: true)
        let none = h.addReference(words: "the tiles", query: "tile", at: CGPoint(x: 400, y: 400))
        let row = { (id: ShapeID) throws -> ContentsLabel in
            try require(try require(try require(h.editor.tableOfContents).entries.first { $0.id == id }).label)
        }
        expectEqual(try row(all).badge, nil, "not answered yet")
        h.answer()
        let counted = try row(all)
        expectEqual(counted.text, "the boxes")
        expectEqual(counted.systemImage, "magnifyingglass")
        expectEqual(counted.badge, "3")
        expect(try row(none).isPlaceholder, "found nothing: dimmed")
    },
    test("past a thousand the count is cut down, never rounded up, the header says it whole, and every match is stood for") {
        let h = try referenceHarness()
        let ids = boxes(h, 1_299)
        let all = h.addReference(words: "the boxes", query: "box", all: true, at: CGPoint(x: 400, y: 400))
        h.answer()
        let label = try require(try require(try require(h.editor.tableOfContents).entries.first { $0.id == all }).label)
        expectEqual(label.badge, "1.2k", "1,299 is 1.2 thousand, not 1.3")
        expectEqual(try header(h, all).subtitle, "\(1_299.formatted()) matches")
        expectEqual(h.standsFor(all), ids, "all of them, in file order")
    },
])
