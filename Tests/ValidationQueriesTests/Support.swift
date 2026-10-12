import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology
import Validation

// Fixtures only: CanvasTesting's cards, tags and pockets (whose boards nest), with rules of this
// target's, each counting its runs: a card whose text starts "bad" has an error and one whose text
// starts "meh" a warning; a tag whose shape isn't on its board has an error, which only a rule run
// against the tag's own board gets right.

/// How many times the fixtures' rules have run.
@MainActor final class RuleRuns {
    var count = 0
}

/// The rules.
func rulesPlugin(_ runs: RuleRuns) -> Contributor {
    Contributor(id: "rules") { registrar in
        registrar.validate(Card.self) { card, _ in
            runs.count += 1
            if card.props.text.hasPrefix("bad") { return [.error("It's bad.")] }
            if card.props.text.hasPrefix("meh") { return [.warning("It's so-so.")] }
            return []
        }
        registrar.validate(Tag.self) { tag, context in
            runs.count += 1
            guard let target = tag.props.target, context.shape(target) == nil else { return [] }
            return [.error("Its shape isn't on its board.")]
        }
    }
}

@MainActor func validationPlugins(_ runs: RuleRuns, more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [TopologyPlugin(), FixturesPlugin(), CardsPlugin(), PocketsPlugin(), ValidationPlugin(), rulesPlugin(runs), QueriesPlugin(),
     ValidationQueriesPlugin()] + more
}

func uuid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }

let unit = CGRect(x: 0, y: 0, width: 100, height: 60)

func record<P: ShapeProps>(_ n: Int, _ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id(n), props)) }

/// On the top board: card 1 "bad", card 2 "meh", card 3 "fine", pocket 4 and tag 5 on card 3. On
/// the pocket's board: card 11 "bad", card 12 "meh", tag 13 on card 12 (on its board) and tag 14 on
/// card 1 (not on its board). In file order: 1, 2, 3, 4, 11, 12, 13, 14, 5.
func checkedFile() -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: [record(1, Card(unit, text: "bad")), record(2, Card(unit, text: "meh")),
                                             record(3, Card(unit, text: "fine")), record(4, Pocket(unit)), record(5, Tag(target: id(3)))]),
               children: [id(4): CanvasDocument(shapes: [record(11, Card(unit, text: "bad")), record(12, Card(unit, text: "meh")),
                                                         record(13, Tag(target: id(12))), record(14, Tag(target: id(1)))])])
}

/// A harness on the file, Validation having checked the board shown.
@MainActor func checkedHarness(_ runs: RuleRuns, more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let h = try EditorHarness(plugins: validationPlugins(runs, more: more), file: checkedFile())
    _ = h.editor.validation?.results
    return h
}

/// The shapes a query matches on `h`'s editor, in the order it lists them, the main run loop turned
/// while it runs.
@MainActor func matched(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> [ShapeID] {
    let queries = try require(h.editor.queries, file: file, line: line)
    return try awaitResult(file: file, line: line) {
        try await queries.run(QueryRequest(text, limit: QueryBudget.maxRows, properties: .none))
    }.rows.map(\.id)
}

/// Why `h`'s editor refuses a query; nil if it answers.
@MainActor func refusal(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> QueryError? {
    do {
        _ = try matched(text, on: h, file: file, line: line)
        return nil
    } catch let error as QueryError {
        return error
    }
}

/// Something a closure sets and a test reads.
@MainActor final class Flag {
    var value = false
}
