import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// What queries cost the app between them: nothing. No snapshot outlives its query, however it ends;
// a commit reaches nothing of theirs; and a switch of board works out no change set for them.

/// Keeps whether each switch's change set had been worked out by the time it heard of it.
@MainActor final class SwitchWatch {
    var workedOut: [Bool] = []
}

private final class SwitchWatcher {
    let watch: SwitchWatch
    init(watch: SwitchWatch) { self.watch = watch }
}

extension SwitchWatcher: EditorService {
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        watch.workedOut.append(change.hasWorkedOutChanges)
    }
}

@MainActor let upkeepTests = Suite("Upkeep", [
    test("no snapshot outlives its query, however it ends") {
        let slow = SlowWord()
        let h = try shelf(more: [slowPlugin(slow)])
        let queries = try require(h.editor.queries)
        expectEqual(queries.liveSnapshots, 0)
        _ = try answer("*", on: h)
        expectEqual(queries.liveSnapshots, 0, "answered")
        expectEqual(queries.captures, 1)
        _ = try answer("*", on: h, countOnly: true)
        expectEqual(queries.liveSnapshots, 0, "counted")
        expectEqual(try refusedAnswer(#""Nope""#, on: h)?.reason, .unknownTitle)
        expectEqual(queries.liveSnapshots, 0, "refused once it had the file")
        expectEqual(try refusedAnswer("chor", on: h)?.reason, .unknownKind)
        expectEqual(queries.captures, 3, "refused before it took up the file: no snapshot")
        expectEqual(try refusedAnswer("zebra", on: h)?.reason, .unknownKind)
        expectEqual(queries.captures, 4, "a word like no kind takes up the file to read the titles, which it may be one of")
        expectEqual(queries.liveSnapshots, 0, "and lets go of it")
        slow.onAsk = { _ in h.wait(8_000) }
        expectEqual(try refusedAnswer("chore:slow", on: h)?.reason, .tooSlow)
        expectEqual(queries.liveSnapshots, 0, "too slow")
        let running = Running()
        slow.onAsk = { _ in running.task?.cancel() }
        let task = Task { @MainActor in try await queries.run(QueryRequest("chore:slow")) }
        running.task = task
        expectEqual(try thrown(by: task)?.reason, .cancelled)
        expectEqual(queries.liveSnapshots, 0, "cancelled")
        slow.onAsk = nil
        let queriesTitles = try awaitResult { try await queries.titles(for: "Alpha", limit: 5) }
        expectEqual(queriesTitles.first?.title, "Alpha")
        _ = try awaitResult { try await queries.whereThePersonIs(selectedLimit: 5) }
        expectEqual(queries.liveSnapshots, 0, "titles and where the person is")
    },
    test("a commit while a query holds its snapshot lands, and the snapshot still goes with the query") {
        let slow = SlowWord()
        let h = try shelf(more: [slowPlugin(slow)])
        let queries = try require(h.editor.queries)
        slow.onAsk = { _ in
            guard slow.calls == 1 else { return }
            h.add(Chore(unit), id: id(50))
            h.editor.transact { $0.moveBox(id(1), to: CGPoint(x: 40, y: 40)) }
        }
        expectEqual(try matched("chore:slow", on: h), [1, 11, 21].map(id), "as the query took the file up")
        expectEqual(queries.liveSnapshots, 0)
        slow.onAsk = nil
        expectEqual(try matched("chore", on: h), [1, 11, 21, 50].map(id), "the next query takes it up afresh")
    },
    test("commits cost queries nothing: nothing is kept between them, and each takes up the file afresh") {
        let h = try shelf()
        let queries = try require(h.editor.queries)
        _ = try answer("chore", on: h)
        let (captures, encoded, walks) = (queries.captures, queries.recordsEncoded, queries.universeWalks)
        for step in 0..<20 {
            h.editor.transact { $0.moveBox(id(1), to: CGPoint(x: step, y: step)) }
        }
        h.add(Chore(unit), id: id(60))
        h.editor.transact { $0.delete([id(4)]) }
        expectEqual(queries.captures, captures, "no commit takes anything up")
        expectEqual(queries.recordsEncoded, encoded)
        expectEqual(queries.universeWalks, walks)
        expectEqual(queries.liveSnapshots, 0)
        expectEqual(try matched("chore, link", on: h), [1, 11, 21, 3, 60].map(id))
        expectEqual(queries.universeWalks, walks + 1, "the next query walks the file as it is")
    },
    test("a switch of board works out no change set for queries") {
        let watch = SwitchWatch()
        let h = try shelf(more: [Contributor(id: "watch") { registrar in registrar.service { _ in SwitchWatcher(watch: watch) } }])
        _ = try answer("*", on: h)
        expect(h.enter(id(2)))
        expect(h.editor.showBoard(.root))
        expectEqual(watch.workedOut, [false, false])
        _ = try answer("*", on: h)
        expect(h.enter(id(12)))
        expectEqual(watch.workedOut, [false, false, false])
    },
])
