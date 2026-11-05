import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Chrome
import Mentions
import TestKit
import TextEditing
import Titles

// A candidate and where it is (`MentionChoice`): the containers it is inside, else the name of the board a
// shape is on, nil on the board shown, and the lines a list shows for choices, headless.

/// A file of three boards: the root, board A (a pocket called "Clients", where the text is) and board B
/// (a pocket nothing calls anything).
@MainActor private struct Boards {
    let h: EditorHarness
    let owner = ShapeID(), a = ShapeID(), b = ShapeID()
    let onRoot = ShapeID(), onA = ShapeID(), onA2 = ShapeID(), onB = ShapeID()

    init() throws {
        @MainActor func plate(_ id: ShapeID, _ title: String, x: Double) -> AnyShapeRecord {
            var plate = ShapeRecord(id: id, Plate(CGRect(x: x, y: 0, width: 120, height: 80)))
            plate[TitleProperty.self] = title
            return AnyShapeRecord(plate)
        }
        var clients = ShapeRecord(id: a, Pocket(CGRect(x: 0, y: 1200, width: 100, height: 100)))
        clients[TitleProperty.self] = "Clients"
        let root = CanvasDocument(shapes: [AnyShapeRecord(clients), AnyShapeRecord(ShapeRecord(id: b, Pocket(CGRect(x: 200, y: 1200, width: 100, height: 100)))),
                                           plate(onRoot, "Ann Lee", x: 400)])
        let boardA = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: owner, Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: "Mine"))),
                                             plate(onA, "Ann Lee", x: 300), plate(onA2, "Anders", x: 500)])
        let titledPockets = Contributor(id: "titled-pockets") {
            $0.title(Pocket.self)
            $0.mentionable(Pocket.self, label: { _ in "Pouch" })
        }
        h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin(), titledPockets]),
                              file: CanvasFile(root: root, children: [a: boardA, b: CanvasDocument(shapes: [plate(onB, "Ann Lee", x: 0)])]))
        expect(h.editor.showBoard(BoardID(owner: a)))
    }

    var state: MentionState { h.editor.mentionState }
}

@MainActor let choiceTests = Suite("Choices", [
    test("a shape's board is nil on the board shown, else what Boards calls it (its owner's title, else its kind's placeholder or name), and Board for the root") {
        let r = try Boards()
        expectEqual(r.state.boardName(ofShape: r.onA), nil)
        expectEqual(r.state.boardName(ofShape: r.onRoot), "Board")
        expectEqual(r.state.boardName(ofShape: r.onB), r.h.editor.registry.label(of: Pocket.kind).name, "a pocket with no title, whose kind says no placeholder here")
        expectEqual(r.state.boardName(ofShape: ShapeID()), nil, "a shape that isn't in the file")
        expect(r.h.editor.showBoard(.root))
        r.h.editor.rename(r.b, "Vendors")
        expect(r.h.editor.showBoard(BoardID(owner: r.a)))
        expectEqual(r.state.boardName(ofShape: r.onB), "Vendors")
        expect(r.h.editor.showBoard(BoardID(owner: r.b)))
        expectEqual(r.state.boardName(ofShape: r.onB), nil, "the board shown, whichever it is")
        expectEqual(r.state.boardName(ofShape: r.onA), "Clients")
    },

    test("choices carry each candidate's place, in order") {
        let r = try Boards()
        let found = r.state.candidates(matching: "ann", in: AnyMentionable.self, for: r.owner).matches
        let choices = r.state.choices(found)
        expectEqual(choices.map(\.candidate), found)
        expectEqual(choices.map { $0.place?.text }, found.map { r.state.place(ofShape: $0.id)?.text })
        expectEqual(choices.map { $0.place?.text }, found.map { r.state.boardName(ofShape: $0.id) }, "a shape in no frame says its board")
        expectEqual(Set(choices.compactMap { $0.place?.text }), ["Board", r.h.editor.registry.label(of: Pocket.kind).name])
    },

    test("a line is the name, the matched letters, the kind's symbol and tint, and the place; two alike read Kind · Place; spoken with its place and position") {
        let r = try Boards()
        let found = r.state.candidates(matching: "an", in: AnyMentionable.self, for: r.owner).matches
        let choices = r.state.choices(found)
        let items = MentionChoice.items(choices)
        expectEqual(items.count, choices.count)
        expectEqual(items.map(\.title), choices.map(\.candidate.appearance.label))
        expectEqual(items.map(\.matched), choices.map(\.candidate.matched))
        expectEqual(items.map(\.symbol), choices.map(\.candidate.appearance.systemImage))
        for (n, item) in items.enumerated() {
            let appearance = choices[n].candidate.appearance
            let place = choices[n].place?.text
            expectEqual(item.spoken, "\(appearance.label), \(appearance.kindName)\(place.map { ", in " + $0 } ?? ""), \(n + 1) of \(items.count)")
            expectEqual(item.detailTruncatesHead, place != nil, "a place too long for its room is cut at its start, alike or not: the container a shape is in is last")
            if appearance.label == "Ann Lee" {
                expectEqual(item.detail, (["Plate"] + (place.map { [$0] } ?? [])).joined(separator: " · "), "three called alike: the kind, then the place when it isn't the board shown")
            } else {
                expectEqual(item.detail, place, "alone: the place, nil on the one shown")
            }
        }
        expectEqual(items.filter { $0.title == "Ann Lee" }.count, 3)
        expectEqual(items.first { $0.title == "Anders" }?.detail, nil)

        let alone = MentionChoice.items(choices.filter { $0.candidate.appearance.label == "Ann Lee" && $0.place?.text == "Board" })
        expectEqual(alone.map(\.detail), ["Board"], "one alone is its place: the board's name")
        expectEqual(alone.map(\.spoken), ["Ann Lee, Plate, in Board, 1 of 1"])
    },

    test("the top board goes by the file's name, \"Board\" only while it has none; a row's place is its steps, boards semibold, folded in the row's room") {
        let r = try Boards()
        r.h.editor.nameRoot("Shop")
        expectEqual(r.state.boardName(ofShape: r.onRoot), "Shop")
        let found = r.state.candidates(matching: "an", in: AnyMentionable.self, for: r.owner).matches
        let choices = r.state.choices(found)
        let items = MentionChoice.items(choices)
        expect(choices.contains { $0.place?.text == "Shop" }, "a shape on the root: the file's name")
        for (item, choice) in zip(items, choices) {
            expectEqual(item.place?.steps, choice.place.map { $0.steps }, "the row folds the steps")
            if choice.place != nil { expectEqual(item.place?.lead, item.title == "Ann Lee" ? "Plate · " : "", "two alike: the kind leads") }
        }
        let root = try require(choices.first { $0.place?.text == "Shop" }.flatMap { MentionChoice.items([$0]).first?.place })
        expectEqual(root.steps, [PlaceStep(name: "Shop", opensBoard: true)], "the board that leads is a board")
        let long = MentionPlace(names: [ContainerName(title: "Shop", placeholder: "Subboard", opensBoard: true), ContainerName(title: "Payments and disputes", placeholder: "Frame"),
                                        ContainerName(title: "Chargebacks in review", placeholder: "Frame"), ContainerName(title: "Disputes", placeholder: "Frame")])
        let place = try require(long.caretPlace(lead: "Note · "))
        expectEqual(place.text(in: 1000), "Note · Shop › Payments and disputes › Chargebacks in review › Disputes")
        let folded = place.text(in: 170)
        expect(folded.hasPrefix("Note · Shop") && folded.contains("…") && folded.hasSuffix("Disputes"), "folded: \(folded)")
        expectEqual(MentionPlace(text: "elsewhere").caretPlace(), nil, "a place that is only text is cut as before")
    },
])
