import Canvas
import Foundation
import Queries
import Topology

// What a run says once the file's answers have come. A check's verdict is sometimes an answer that comes a moment after a
// commit (a standing query's, which Topology's settling waits for), so the check a run asks before it commits cannot judge what
// the run wrote: it answers only for a shape the run left as it was. A real run, `canvas draw` or `canvas apply`, therefore
// says what it can, commits, and then waits for the file's answers to settle (`QueryBudget.settleWait`) and asks its check
// again, over the committed file, of what it wrote and what it touched, saying each issue it didn't say already
// (`laterIssues`). Draw knows no rule: it asks the same `DrawCheck`. A dry run commits nothing, so nothing comes, and says what
// it said; a rehearsal runs on a copy whose scheduler is stopped, and is never answered.

/// What a run keeps for its second look (`laterIssues`), never said: the shapes its statements wrote with the line of each and
/// the issues the run said of it, and the shapes it looked at that it did not write (`brought`), each with the issues it had as the
/// run found the board or left it, and the line of the statement that brought what the run said of it. The second look walks
/// nothing else.
@MainActor
struct DrawAftermath {
    /// A shape a statement wrote: its line, how the run named it, and every issue its check gave as the run left it (what a shape
    /// still needs among them, which its row's `problems` say).
    struct Written {
        let line: Int
        let name: String
        let id: ShapeID
        let said: [DrawIssue]
    }

    /// A shape the run looked at and did not write: the issues it had before and as the run left it, and the statement whose
    /// writes alone reached it when the run said something of it.
    struct Looked {
        let id: ShapeID
        let line: Int?
        let known: [DrawIssue]
    }

    let written: [Written]
    let looked: [Looked]
    /// The shapes the run said an issue of (`brought`), and how many more it counted: the second look's limit is what is left of
    /// `Drawing.broughtLimit`, and its count is added to the run's.
    let said: Set<ShapeID>
    let more: Int
    /// What the rows of shapes restated as they are say they still need, by shape (`Drawing.brought`).
    let restated: [ShapeID: Set<String>]
    /// How a message names a shape of the committed file, as the run named the shapes it brought an issue to.
    let named: @MainActor (AnyShapeRecord, BoardID, ShapeContext) -> String

    /// The issues the check gives now, over the committed file, that the run did not say, as warnings: of a shape it wrote on the
    /// line of its statement, worded as the run words one; of a shape it looked at, as `Drawing.brought` says one (its line the
    /// run's, if it found one; at most `Drawing.broughtLimit` shapes, then a count).
    func issues(in editor: CanvasEditor) -> [DrawWarning] {
        guard let check = editor.registry.drawCheck else { return [] }
        let committed = CommittedShapes(editor)
        var warnings: [DrawWarning] = []
        var seen: Set<ShapeID> = []
        for shape in written where seen.insert(shape.id).inserted {
            guard let found = committed.look(shape.id) else { continue }
            var said = Multiset(shape.said)
            for issue in check.check(found.record, found.shapes) where !said.take(issue) {
                // What a shape still needs is its row's, once the row says it.
                if issue.isIncomplete, restated[shape.id]?.contains(issue.message) == true { continue }
                warnings.append(DrawWarning(line: shape.line, shape.name, issue: issue, about: shape.id))
            }
        }
        var broken: [(name: String, id: ShapeID, line: Int?, issues: [DrawIssue])] = []
        for shape in looked where !seen.contains(shape.id) {
            guard let found = committed.look(shape.id) else { continue }
            var known = Multiset(shape.known)
            let new = check.check(found.record, found.shapes).filter { issue in
                guard !known.take(issue) else { return false }
                return !(issue.isIncomplete && restated[shape.id]?.contains(issue.message) == true)
            }
            if !new.isEmpty { broken.append((named(found.record, found.board, found.shapes), shape.id, shape.line, new)) }
        }
        broken.sort { ($0.name, $0.id.description) < ($1.name, $1.id.description) }
        // A shape the run said already is said again without counting; the rest take what is left of the limit.
        var room = max(Drawing.broughtLimit - said.count, 0)
        var more = self.more
        var counted = false
        for shape in broken {
            if !said.contains(shape.id) {
                guard room > 0 else { more += 1; counted = true; continue }
                room -= 1
            }
            for issue in shape.issues { warnings.append(DrawWarning(line: shape.line, shape.name, issue: issue, about: shape.id)) }
        }
        if counted {
            let ask = check.rest.map { ": ask \($0)" } ?? ""
            var count = DrawWarning(line: nil, "and \(more) more \(more == 1 ? "shape now has" : "shapes now have") issues\(ask)")
            count.countsMore = true
            warnings.append(count)
        }
        return warnings
    }
}

/// A count of what is in a list, to take one away at a time (issues are compared by message, field and level, as a multiset).
struct Multiset<Element: Hashable> {
    private var counts: [Element: Int] = [:]

    init(_ elements: [Element]) {
        for element in elements { counts[element, default: 0] += 1 }
    }

    /// Takes one `element` out if there is one: whether there was.
    mutating func take(_ element: Element) -> Bool {
        guard let count = counts[element], count > 0 else { return false }
        counts[element] = count - 1
        return true
    }
}

/// The file's shapes as it holds them now: a shape, its board and the shapes of its board.
@MainActor
struct CommittedShapes {
    private let editor: CanvasEditor

    init(_ editor: CanvasEditor) {
        self.editor = editor
    }

    /// A shape of the committed file, with its board and its board's shapes; nil if it is gone.
    func look(_ id: ShapeID) -> (record: AnyShapeRecord, board: BoardID, shapes: ShapeContext)? {
        guard let board = editor.file.board(containing: id) else { return nil }
        let shapes = board == editor.board ? editor.shapeContext : editor.shapeContext.over(editor.contents(of: board))
        guard let record = shapes.shape(id) else { return nil }
        return (record, board, shapes)
    }
}

/// Waits for the file's answers to settle, as long as `QueryBudget.settleWait` on the editor's scheduler: whether they have. Without
/// Topology nothing is answered later.
@MainActor
private func answersSettled(in editor: CanvasEditor) async -> Bool {
    guard let topology = editor.topology else { return true }
    return await topology.settled(timeout: QueryBudget.settleWait, checksOnly: true)
}

/// What a run still says once its answers have come, in a warning with no line, when they have not all: the check's `rest`
/// lists them.
@MainActor
private func stillArriving(in editor: CanvasEditor) -> DrawWarning {
    let ask = editor.registry.drawCheck?.rest.map { ": ask \($0)" } ?? ""
    return DrawWarning(line: nil, "Answers are still arriving, so the issues said may not be all there are\(ask)")
}

/// A real run (`canvas draw`, with or without `--drawing`), after it has committed, with what its check says once the file's
/// answers have come: the run's own warnings, and, for each issue the check gives now, over the committed file, of the shapes the
/// run wrote and those it touched, that the run did not say, one more: of a shape it wrote on its statement's line (worded as the
/// run words one), of a shape it touched as the run words one it brings (`Drawing.brought`), its line the one the run found for
/// the shape if it found one. An issue a standing query reports is an answer that comes after the commit: the run could not
/// say it, and this does.
///
/// It waits for the answers (`editor.topology?.settled(timeout:)`, bounded by `QueryBudget.settleWait` on the editor's
/// scheduler); when the bound passes first, it says what has come and one warning with no line that answers are still coming
/// (the check's `rest` lists them). A dry run, a run that wrote and touched nothing and one with no check come back as they
/// were, at once: nothing comes after a dry run's, which commits nothing. A task cancelled while it waits answers nothing more
/// (the run is committed already).
@MainActor
public func laterIssues(of result: DrawResult, in editor: CanvasEditor) async -> DrawResult {
    var result = result
    guard result.dryRun != true, let after = result.aftermath else { return result }
    result.aftermath = nil
    let settled = await answersSettled(in: editor)
    guard !Task.isCancelled else { return result }
    let later = after.issues(in: editor)
    // A count the second look makes includes the run's own: one count, of every shape not said.
    if later.contains(where: \.countsMore) { result.warnings.removeAll(where: \.countsMore) }
    result.warnings += later
    if !settled { result.warnings.append(stillArriving(in: editor)) }
    // In line order, the run's first, those with no line last.
    result.warnings = result.warnings.enumerated().sorted { ($0.element.line ?? .max, $0.offset) < ($1.element.line ?? .max, $1.offset) }.map(\.element)
    return result
}

/// A document's run (`canvas apply`) after the drawing is in the file, as `laterIssues(of: DrawResult)`: the issues of the drawing's
/// own shapes, as its run says them, once the answers have come, each said once, as the run words one.
@MainActor
public func laterIssues(of result: DocumentResult, in editor: CanvasEditor) async -> DocumentResult {
    var result = result
    guard result.dryRun != true, let after = result.aftermath else { return result }
    result.aftermath = nil
    let settled = await answersSettled(in: editor)
    guard !Task.isCancelled else { return result }
    result.warnings += after.issues(in: editor)
    if !settled {
        let warning = stillArriving(in: editor)
        result.warnings.append(DocumentResult.Warning(key: nil, edge: nil, message: warning.message, severity: warning.severity.rawValue, attribute: nil))
    }
    return result
}

/// What a document's run keeps for its second look (`laterIssues(of: DocumentResult)`), never said: each shape of the drawing (a
/// node's, an edge's arrow's or pill's) with its key or its edge's place and the issues the run said of it.
@MainActor
struct DocumentAftermath {
    struct Drawn {
        let id: ShapeID
        let key: String?
        let edge: Int?
        let said: [DrawIssue]
    }

    let drawn: [Drawn]
    /// A message with each id it names of the document's shapes said as that node's key.
    let keyed: @MainActor (String) -> String

    /// The issues the check gives now of the drawing's shapes that its run did not say, as the run says one.
    func issues(in editor: CanvasEditor) -> [DocumentResult.Warning] {
        guard let check = editor.registry.drawCheck else { return [] }
        let committed = CommittedShapes(editor)
        var warnings: [DocumentResult.Warning] = []
        for shape in drawn {
            guard let found = committed.look(shape.id) else { continue }
            var said = Multiset(shape.said)
            for issue in check.check(found.record, found.shapes) where !issue.isIncomplete && !said.take(issue) {
                let name = shape.key.map(quoted) ?? "edges[\(shape.edge ?? 0)]"
                warnings.append(DocumentResult.Warning(key: shape.key, edge: shape.edge, message: "\(name): \(keyed(issue.message))",
                                                       severity: issue.isError ? "error" : "warning", attribute: issue.field))
            }
        }
        return warnings
    }
}
