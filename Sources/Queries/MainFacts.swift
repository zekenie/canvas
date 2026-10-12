import Canvas
import QueryLanguage

/// What only the main actor can say about shapes, for one query: a derived name (the names point's
/// `derived`) and a word's verdict (its `onMain`), asked by the evaluation in slices, each a main-actor
/// job of its own that lasts `QueryBudget.slice` plus at most the one record that crosses it. The
/// evaluation asks for the next slice only once it has the last one's answers, so a query never has
/// more than one waiting on the main queue, and input, drawing and the slices of other queries
/// running at once (each has a `MainFacts` of its own) run between them.
///
/// Each is asked about the shape as the app has it when the slice runs, not as the query took it up:
/// the id is looked up in the live file (the board it's on now too), and a shape gone since, kept
/// aside or on a board the app can't show has no name and fails every word. So an answer's derived
/// names and verdicts may be newer than its attributes and structure, never older.
///
/// It holds the editor weakly, so an evaluation never keeps a closed file's editor alive; asked once
/// the editor is gone, it refuses the query `board_closed`.
@MainActor
final class MainFacts {
    /// A word's `onMain`, with what its `prepare` took.
    struct Verdict {
        let ask: @MainActor (AnyShapeRecord, BoardID, any Sendable, QueryMainContext) -> Bool
        let prepared: any Sendable
    }

    /// A word's `problems`, with what its `prepare` took.
    struct Problemer {
        let ask: @MainActor (AnyShapeRecord, BoardID, any Sendable, QueryMainContext) -> [ShapeProblem]
        let prepared: any Sendable
    }

    private weak var editor: CanvasEditor?
    /// `editor.revision` as the query took up the file.
    private let revision: Int
    private let derived: (@MainActor (AnyShapeRecord, Registry) -> String?)?
    private let verdicts: [String: Verdict]
    private let problemers: [String: Problemer]
    /// The boards' contexts the query's slices made (`QueryMainContext.shapes(on:)`).
    private let kept = KeptContexts()

    /// How many slices ran, their thread CPU in all, the longest, and the most one record could have
    /// cost (the longest stretch between two reads of a slice's clock).
    private(set) var slices = 0
    private(set) var total: UInt64 = 0
    private(set) var longest: UInt64 = 0
    private(set) var costliest: UInt64 = 0
    /// How many derived names and verdicts were asked.
    private(set) var titlesAsked = 0
    private(set) var verdictsAsked = 0
    /// How many shapes were asked what's the matter with them.
    private(set) var problemsAsked = 0

    init(editor: CanvasEditor, revision: Int, derived: (@MainActor (AnyShapeRecord, Registry) -> String?)?, verdicts: [String: Verdict],
         problemers: [String: Problemer] = [:]) {
        self.editor = editor
        self.revision = revision
        self.derived = derived
        self.verdicts = verdicts
        self.problemers = problemers
    }

    /// The derived names of as many of `ids` as a slice holds, from the first: each folded, nil for
    /// none (and for a shape gone since, or of a kind with no derived names). `done` is how many.
    func titles(of ids: ArraySlice<ShapeID>) throws(QueryError) -> (answers: [ShapeID: String?], done: Int) {
        let context = try context()
        return slice(ids) { id -> String? in
            titlesAsked += 1
            guard let derived, let shape = context.shape(id) else { return nil }
            return derived(shape.record, context.registry)
        }
    }

    /// `word`'s verdict on as many of `ids` as a slice holds, from the first: false for a shape gone
    /// since, and for a word with no `onMain`. `done` is how many.
    func verdicts(_ word: String, of ids: ArraySlice<ShapeID>) throws(QueryError) -> (answers: [ShapeID: Bool], done: Int) {
        let context = try context()
        let verdict = verdicts[word]
        return slice(ids) { id -> Bool in
            verdictsAsked += 1
            guard let verdict, let shape = context.shape(id) else { return false }
            return verdict.ask(shape.record, shape.board, verdict.prepared, context)
        }
    }

    /// What each of `words` says is the matter with as many of `ids` as a slice holds, from the first:
    /// each shape's problems in the order of `words`, one that two words give once. A shape gone since
    /// has none. `done` is how many.
    func problems(_ words: [String], of ids: ArraySlice<ShapeID>) throws(QueryError) -> (answers: [ShapeID: [ShapeProblem]], done: Int) {
        let context = try context()
        let askers = words.compactMap { problemers[$0] }
        return slice(ids) { id -> [ShapeProblem] in
            problemsAsked += 1
            guard let shape = context.shape(id) else { return [] }
            var found: [ShapeProblem] = []
            for asker in askers {
                for problem in asker.ask(shape.record, shape.board, asker.prepared, context) where !found.contains(problem) { found.append(problem) }
            }
            return found
        }
    }

    /// What a slice asks with: refused if the query's been cancelled, or its editor is gone.
    private func context() throws(QueryError) -> QueryMainContext {
        guard !Task.isCancelled else { throw .cancelledQuery }
        guard let editor else { throw .boardClosed }
        return QueryMainContext(editor: editor, revision: revision, kept: kept)
    }

    /// Asks `ask` of `ids` in order until `QueryBudget.slice` of this thread's CPU has gone, at least
    /// one done. The clock is read after the first record, then every `QueryBudget.clockStride`
    /// records while the time left holds that many at the pace so far, and after every record once
    /// `QueryBudget.everyRecordAfter` has gone; a cancellation seen at a read ends the slice there.
    private func slice<Answer>(_ ids: ArraySlice<ShapeID>, _ ask: (ShapeID) -> Answer) -> (answers: [ShapeID: Answer], done: Int) {
        let start = threadCPU()
        let budget = QueryBudget.slice.nanoseconds
        let careful = QueryBudget.everyRecordAfter.nanoseconds
        var answers: [ShapeID: Answer] = [:]
        var done = 0, nextRead = 1, lastRead = start
        for id in ids {
            answers[id] = ask(id)
            done += 1
            guard done == nextRead else { continue }
            let now = threadCPU()
            costliest = max(costliest, now - lastRead)
            lastRead = now
            let spent = now - start
            if spent >= budget || Task.isCancelled { break }
            if spent >= careful {
                nextRead = done + 1
            } else {
                // As many as the time left before being careful holds at the pace so far, up to the stride.
                let pace = max(spent / UInt64(done), 1)
                nextRead = done + Int(min(UInt64(QueryBudget.clockStride), max((careful - spent) / pace, 1)))
            }
        }
        let end = threadCPU()
        // The records after the last read, when the ids ran out first: a stretch like any other.
        costliest = max(costliest, end - lastRead)
        let spent = end - start
        slices += 1
        total += spent
        longest = max(longest, spent)
        return (answers, done)
    }
}
