import AppKit
import Canvas
import CanvasTesting
import Mentions
import TestKit
import Titles

// MentionLabels: the names mentions show, taken from the state to read anywhere.

/// A file whose root holds a jot mentioning plate "Groceries" (on a pocket's board), token "Milk",
/// a box (which can't be mentioned) and a shape that isn't in the file, and plate "Errands", which
/// nothing mentions.
@MainActor private struct Labelled {
    let h: EditorHarness
    let pocket = ShapeID(), groceries = ShapeID(), errands = ShapeID(), milk = ShapeID(), box = ShapeID(), gone = ShapeID(), jot = ShapeID()
    var editor: CanvasEditor { h.editor }
    var state: MentionState { h.editor.mentionState }
    var mentioned: [ShapeID] { [groceries, milk, box, gone] }

    init() throws {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        var plate = ShapeRecord(id: groceries, Plate(frame))
        plate[TitleProperty.self] = "Groceries"
        var other = ShapeRecord(id: errands, Plate(frame))
        other[TitleProperty.self] = "Errands"
        let text = mentioning([.text("Buy "), .mention(groceries, label: "Old name"), .text(", "), .mention(milk, label: "Milk"),
                               .text(", "), .mention(box, label: "Box"), .text(" and "), .mention(gone, label: "Gone")])
        let root: [AnyShapeRecord] = [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(frame))),
                                      AnyShapeRecord(ShapeRecord(id: jot, Jot(frame, text: text))),
                                      AnyShapeRecord(ShapeRecord(id: milk, Token(frame, caption: "Milk"))),
                                      AnyShapeRecord(ShapeRecord(id: box, Box(frame))), AnyShapeRecord(other)]
        h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()]),
                              file: CanvasFile(root: CanvasDocument(shapes: root), children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(plate)])]))
    }

    var text: MentionText { h.editor.document[jot]!.typed(as: Jot.self)!.props.text }

    /// Every mentioned shape's label is what resolving it says a mention shows, and the text reads
    /// through them as the state reads it.
    func expectAgreement(_ note: String, file: StaticString = #fileID, line: UInt = #line) {
        let labels = state.labels
        for id in mentioned {
            expectEqual(labels.label(of: id), state.resolve(id).appearance?.label, note, file: file, line: line)
        }
        expectEqual(text.plainText { labels.label(of: $0) }, state.plainText(text), note, file: file, line: line)
    }
}

/// Mention text read through labels off the main actor, as a query reads it.
private nonisolated func plainTextOffMain(_ text: MentionText, _ labels: MentionLabels) -> String {
    text.plainText { labels.label(of: $0) }
}

@MainActor let labelsTests = Suite("Mention labels", [
    test("each mentioned shape's label is what a mention of it shows: live names, on any board, and none for a shape missing or unavailable") {
        let l = try Labelled()
        let labels = l.state.labels
        expectEqual(labels.label(of: l.groceries), "Groceries", "on another board")
        expectEqual(labels.label(of: l.milk), "Milk")
        expectEqual(labels.label(of: l.box), nil, "a box can't be mentioned: unavailable")
        expectEqual(labels.label(of: l.gone), nil, "missing")
        expectEqual(labels.label(of: l.errands), nil, "nothing mentions it")
        expectEqual(MentionLabels().label(of: l.groceries), nil)
        l.expectAgreement("as opened")
        expectEqual(plainTextOffMain(l.text, labels), "Buy @Groceries, @Milk, @Box and @Gone")
    },
    test("they follow the state through renames, deletions, undo and redo, and a shape mentioned anew") {
        let l = try Labelled()
        l.editor.transact(on: BoardID(owner: l.pocket), "Rename") { $0.update(l.groceries) { $0[TitleProperty.self] = "Food" } }
        l.expectAgreement("renamed on another board")
        expectEqual(l.state.labels.label(of: l.groceries), "Food")
        l.editor.transact("Delete") { $0.delete([l.milk]) }
        l.expectAgreement("deleted")
        expectEqual(l.state.labels.label(of: l.milk), nil)
        l.editor.undo()
        l.expectAgreement("undone")
        expectEqual(l.state.labels.label(of: l.milk), "Milk")
        l.editor.redo()
        l.expectAgreement("redone")
        l.editor.setText(l.jot, mentioning([.mention(l.errands, label: "E")]))
        expectEqual(l.state.labels.label(of: l.errands), "Errands", "mentioned anew")
        expectEqual(l.state.labels.label(of: l.groceries), nil, "no longer mentioned")
    },
    test("labels taken are as the file was then: a rename after doesn't change them") {
        let l = try Labelled()
        let taken = l.state.labels
        let text = l.text
        l.editor.transact(on: BoardID(owner: l.pocket), "Rename") { $0.update(l.groceries) { $0[TitleProperty.self] = "Food" } }
        l.editor.transact { $0.update(l.milk, as: Token.self) { $0.props.caption = "Oat milk" } }
        expectEqual(taken.label(of: l.groceries), "Groceries")
        expectEqual(taken.label(of: l.milk), "Milk")
        expectEqual(plainTextOffMain(text, taken), "Buy @Groceries, @Milk, @Box and @Gone")
        expectEqual(plainTextOffMain(text, l.state.labels), "Buy @Food, @Oat milk, @Box and @Gone")
        let result = try awaitResult { await Task.detached { plainTextOffMain(text, taken) }.value }
        expectEqual(result, "Buy @Groceries, @Milk, @Box and @Gone", "read on another thread")
    },
])
