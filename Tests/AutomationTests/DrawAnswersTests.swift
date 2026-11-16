import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Geometry
import TestKit
import Topology

// What a run says once the file's answers have come (Draw's `laterIssues`, behind `draw` and `apply` as commands that answer later). The
// fixture check's answers come a moment after a commit, as a standing query's do, and keep Topology settling while they're asked:
// a glossy tile is asked about as it's written, and the tile a link ends at as the link is. The check says only what is answered,
// so what a run's own check can't say (it asks before it commits) is said by the look after.

/// When the fixture's answers come: a shape asked about is answered `delay` later, on the editor's scheduler; with `never`, never.
/// What is asked and answered is each editor's own (a document's run draws on a copy, whose scheduler is stopped), found by `asked(by:)`.
@MainActor final class Answers {
    var delay: Duration = .milliseconds(30)
    var never = false
    private(set) weak var editor: CanvasEditor?
    fileprivate func attach(_ editor: CanvasEditor) { self.editor = editor }
    var asking: Set<ShapeID> { editor?.service(Asker.self)?.asking ?? [] }
    var answered: Set<ShapeID> { editor?.service(Asker.self)?.answered ?? [] }
}

/// Asks about the shapes a commit writes: a glossy tile, and the tile a link ends at.
@MainActor fileprivate final class Asker: EditorService {
    private let answers: Answers
    private var source: SettleSource?
    fileprivate(set) var asking: Set<ShapeID> = []
    fileprivate(set) var answered: Set<ShapeID> = []

    init(editor: CanvasEditor, answers: Answers) {
        self.answers = answers
        source = editor.topology?.keepsSettling(edges: false, feedsChecks: true) { [weak self] in self?.asking.isEmpty == false }
    }

    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        for id in changes.edited {
            guard let record = editor.file.record(id) else { continue }
            var subject: ShapeID?
            if let tile = record.typed(as: Tile.self), tile.props.finish == .glossy { subject = id }
            if let link = record.typed(as: Link.self) { subject = link.props.to }
            guard let subject, !asking.contains(subject), !answered.contains(subject) else { continue }
            asking.insert(subject)
            guard !answers.never else { continue }
            _ = editor.scheduler.schedule(after: answers.delay) { [weak self, weak editor] in
                guard let self else { return }
                asking.remove(subject)
                answered.insert(subject)
                editor?.topology?.settleSourceChanged()
            }
        }
    }
}

/// How many times the fixture's check has been asked.
@MainActor private var lateCheckCalls = 0

/// The check: a glossy tile glares and a tile with more than one link is crowded (said at once, as a run's own check can), a tile
/// that was asked about and has answered "answered late" (a moment after).
@MainActor private func lateChecks(_ answers: Answers) -> Contributor {
    Contributor(id: "late-checks") { registrar in
        registrar.service { Asker(editor: $0, answers: answers) }
        registrar.drawChecks(touched: { changes, shapes in
            var found: Set<ShapeID> = []
            for id in changes.shapeIDs { if let to = shapes.shape(id)?.typed(as: Link.self)?.props.to { found.insert(to) } }
            return found
        }, rest: #"canvas query ":crowded""#) { record, shapes in
            guard let tile = record.typed(as: Tile.self) else { return [] }
            lateCheckCalls += 1
            var issues: [DrawIssue] = []
            if tile.props.finish == .glossy { issues.append(DrawIssue("A glossy tile glares.", isError: true, field: "finish")) }
            let links = shapes.document.shapes.filter { $0.typed(as: Link.self)?.props.to == tile.id }.count
            if links > 1 { issues.append(DrawIssue("it has \(links) links, and should have at most 1", isError: true, field: "links")) }
            if shapes.service(Asker.self)?.answered.contains(tile.id) == true { issues.append(DrawIssue("it answered late", isError: true, field: "finish")) }
            return issues
        }
    }
}

/// An editor with names, edges, Topology and the late check; its scheduler is the one given (a real one by default).
@MainActor private func lateEditor(_ answers: Answers, scheduler: any Scheduler = TaskScheduler(), more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    let registry = try Registry(plugins: [DrawPlugin(), AutomationPlugin(), FixturesPlugin(), CardsPlugin(), TilesPlugin(), LinksPlugin(), extras,
                                          namesPlugin(), edgesPlugin(), TopologyPlugin(), lateChecks(answers)] + more)
    let editor = CanvasEditor(registry: registry, scheduler: scheduler)
    answers.attach(editor)
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    editor.camera = Camera(origin: CGPoint(x: 100, y: 100))
    return editor
}

private func late(_ title: String, line: Int?) -> JSON {
    var warning: [String: JSON] = ["message": .string("\"\(title)\": it answered late"), "severity": "error", "attribute": "finish"]
    if let line { warning["line"] = .number(Double(line)) }
    return .object(warning)
}

/// A command started and not waited for: its answer when it comes.
@MainActor private final class Started {
    var result: Result<JSON, RPCError>?
}

@MainActor private func start(_ line: [String], on editor: CanvasEditor, input: String) throws -> Started {
    let spec = try require(editor.registry.automationCommands.first { $0.name == line[0] })
    let params = try spec.params(from: Array(line.dropFirst()), standardInput: { input })
    let started = Started()
    let registry = editor.registry
    Task { @MainActor in
        do throws(RPCError) {
            started.result = .success(try await registry.runAutomationCommand(spec.name, params: .object(params), editor: editor))
        } catch {
            started.result = .failure(error)
        }
    }
    return started
}

@MainActor let drawAnswersTests = Suite("draw: what a run says once the answers have come", [
    test("a real run says an issue that comes after its commit, on the line of the statement that wrote the shape; the run's own check could not") {
        let answers = Answers()
        let editor = try lateEditor(answers)
        let result = try drawn(#"""
        tile "Plain"
        tile "G" finish: glossy right of "Plain"
        """#, on: editor)
        expectEqual(result["warnings"], [
            ["line": 2, "message": #""G": A glossy tile glares."#, "severity": "error", "attribute": "finish"],
            late("G", line: 2),
        ])
        expect(answers.asking.isEmpty, "the answer had come when it said it")
        expectEqual(editor.undoHistory.undoName, "Draw")
    },
    test("an issue the run said already is not said twice, nor is one a shape had before it") {
        let answers = Answers()
        let editor = try lateEditor(answers)
        _ = try drawn(#"tile "G" finish: glossy"#, on: editor)
        // Restated as it is: not written, so not asked about again, and the answered issue is the shape's already.
        let again = try drawn(#"tile "G" finish: glossy"#, on: editor)
        expectEqual(again["warnings"], [], "the answer was in the file's before this run")
        expectEqual(messages(try drawn(#"tile "H" finish: glossy"#, on: editor)).filter { $0.contains("glares") }.count, 1)
    },
    test("a dry run says what it says without the answers, and changes nothing: nothing comes after it") {
        let answers = Answers()
        let editor = try lateEditor(answers)
        let before = editor.document
        let dry = try drawn(#"tile "G" finish: glossy"#, on: editor, ["--dry-run"])
        expectEqual(messages(dry), [#""G": A glossy tile glares."#])
        expectEqual(editor.document, before)
        expect(answers.asking.isEmpty && answers.answered.isEmpty, "nothing was asked: nothing committed")
    },
    test("a shape the run only touched is said as a run says one it brings: a later issue on no line if the run found none, else the statement's") {
        let answers = Answers()
        let editor = try lateEditor(answers)
        tile("Hub", CGRect(x: 400, y: 200, width: 120, height: 80), in: editor)
        tile("A", CGRect(x: 100, y: 200, width: 120, height: 80), in: editor)
        tile("B", CGRect(x: 100, y: 500, width: 120, height: 80), in: editor)
        let first = try drawn(#"edge "A" -> "Hub""#, on: editor)
        expectEqual(first["warnings"], [late("Hub", line: nil)], "the run found nothing of Hub: no line")
        // Hub has answered already, so it is no news; a shape the run found an issue of says its later one on the same line.
        let second = try drawn(#"edge "B" -> "Hub""#, on: editor)
        expectEqual(second["warnings"], [
            ["line": 1, "message": #""Hub": it has 2 links, and should have at most 1"#, "severity": "error", "attribute": "links"],
        ], "Hub's answered issue was there before this run")
        let third = try drawn(#"tile "C" below "A""#, on: editor)
        expectEqual(third["warnings"], [])
    },
    test("the line the run found for a touched shape is the line of its later issue") {
        let answers = Answers()
        let editor = try lateEditor(answers)
        tile("A", CGRect(x: 100, y: 200, width: 120, height: 80), in: editor)
        tile("B", CGRect(x: 100, y: 500, width: 120, height: 80), in: editor)
        tile("C", CGRect(x: 400, y: 200, width: 120, height: 80), in: editor)
        let result = try drawn(#"""
        edge "A" -> "C"
        edge "B" -> "C"
        """#, on: editor)
        // Two statements bring C's crowding together: no line for it, nor for what comes later.
        expectEqual(result["warnings"], [
            ["message": #""C": it has 2 links, and should have at most 1"#, "severity": "error", "attribute": "links"],
            late("C", line: nil),
        ])
    },
    test("answers that are still coming when the bound passes give one warning with no line, saying how to list them; the bound is the editor's scheduler's") {
        let answers = Answers()
        answers.never = true
        let scheduler = ManualScheduler()
        let editor = try lateEditor(answers, scheduler: scheduler)
        let started = try start(["draw", "-"], on: editor, input: #"tile "G" finish: glossy"#)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        expect(started.result == nil, "it waits for the answers")
        expectEqual(editor.undoHistory.undoName, "Draw", "the run is committed already")
        scheduler.advance(by: .milliseconds(1_999))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        expect(started.result == nil, "just under the bound")
        scheduler.advance(by: .milliseconds(1))
        spinRunLoop(until: { started.result != nil })
        let json = try require(started.result).get()
        expectEqual(json["warnings"], [
            ["line": 1, "message": #""G": A glossy tile glares."#, "severity": "error", "attribute": "finish"],
            ["message": #"Answers are still arriving, so the issues said may not be all there are: ask canvas query ":crowded""#, "severity": "warning"],
        ])
        expectEqual(scheduler.pendingCount, 0, "no timer left")
    },
    test("a source that feeds no check holds no run: only the answers a check reads are waited for") {
        let answers = Answers()
        let editor = try lateEditor(answers)
        // What a rule's English verdicts, or a reference's search, is: busy for as long as it likes, read by no check of a run.
        let elsewhere = editor.topology?.keepsSettling(edges: false) { true }
        defer { elsewhere?.cancel() }
        let started = try start(["draw", "-"], on: editor, input: #"tile "G" finish: glossy"#)
        spinRunLoop(until: { started.result != nil }, timeout: 1.5)
        let json = try require(started.result, "answered before the bound (2 s) though a source is busy").get()
        expectEqual(json["warnings"], [
            ["line": 1, "message": #""G": A glossy tile glares."#, "severity": "error", "attribute": "finish"],
            late("G", line: 1),
        ], "the check's answer came, and no warning says answers are still arriving")
    },
    test("what a run says in the second look and in the run is counted once, within one limit of shapes") {
        let answers = Answers()
        let editor = try lateEditor(answers)
        tile("S1", CGRect(x: 0, y: 0, width: 100, height: 60), in: editor)
        tile("S2", CGRect(x: 0, y: 100, width: 100, height: 60), in: editor)
        for i in 1...3 { tile("H\(i)", CGRect(x: 200 * CGFloat(i), y: 0, width: 100, height: 60), in: editor) }
        for i in 1...22 { tile("T\(i)", CGRect(x: 100 * CGFloat(i), y: 300, width: 100, height: 60), in: editor) }
        var lines: [String] = []
        for i in 1...3 { lines += [#"edge "S1" -> "H\#(i)""#, #"edge "S2" -> "H\#(i)""#] }
        for i in 1...22 { lines.append(#"edge "S1" -> "T\#(i)""#) }
        let result = try drawn(lines.joined(separator: "\n"), on: editor)
        let warnings = result["warnings"]?.arrayValue ?? []
        let counts = warnings.compactMap { $0["message"]?.stringValue }.filter { $0.hasPrefix("and ") }
        expectEqual(counts.count, 1, "one count, not the run's and the look's: \(counts)")
        expect(counts.first?.hasPrefix("and 5 more shapes now have issues") == true, "\(counts)")
        let named = Set(warnings.compactMap { $0["message"]?.stringValue }.filter { !$0.hasPrefix("and ") }.compactMap { $0.split(separator: ":").first })
        expectEqual(named.count, 20, "twenty shapes in all: \(named.sorted())")
    },
    test("a dry run asks the check of a shape no more than it says: only its state as the run leaves it") {
        let answers = Answers()
        let editor = try lateEditor(answers)
        tile("A", CGRect(x: 100, y: 200, width: 120, height: 80), in: editor)
        tile("Hub", CGRect(x: 400, y: 200, width: 120, height: 80), in: editor)
        lateCheckCalls = 0
        _ = try drawn(#"edge "A" -> "Hub""#, on: editor, ["--dry-run"])
        expectEqual(lateCheckCalls, 1, "Hub, as the run leaves it: it had no issue, so its earlier version is not asked about")
    },
    test("a request cancelled while it waits answers nothing more: the run is committed") {
        let answers = Answers()
        answers.never = true
        let editor = try lateEditor(answers, scheduler: ManualScheduler())
        let spec = try require(editor.registry.automationCommands.first { $0.name == "draw" })
        let params = try spec.params(from: ["-"], standardInput: { #"tile "G" finish: glossy"# })
        let registry = editor.registry
        let finished = Started()
        let task = Task { @MainActor in
            do throws(RPCError) {
                finished.result = .success(try await registry.runAutomationCommand("draw", params: .object(params), editor: editor))
            } catch {
                finished.result = .failure(error)
            }
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        expect(finished.result == nil)
        task.cancel()
        spinRunLoop(until: { finished.result != nil })
        let json = try require(finished.result).get()
        expectEqual(messages(json), [#""G": A glossy tile glares."#], "what the run said, and no warning that answers are still coming")
        expect(shape("G", in: editor) != nil, "committed")
    },
    test("a result is encoded as it was: what the second look keeps is never said") {
        let answers = Answers()
        let editor = try lateEditor(answers)
        let json = try drawn(#"tile "G" finish: glossy"#, on: editor)
        expectEqual(Set(json.objectValue?.keys.map { $0 } ?? []), ["changes", "warnings", "on"])
        expect(!json.compactText.contains("aftermath"))
    },
    test("a document drawn by canvas apply says the issues of its shapes that come after it is in the file, once, by key; a dry run says none of them") {
        let answers = Answers()
        let editor = try lateEditor(answers, more: [recordsPlugin])
        let document: JSON = ["drawing": "D", "nodes": [
            ["key": "t:g", "kind": "tile", "props": ["label": "G", "finish": "glossy"], "place": ["at": [0, 0]]],
            ["key": "t:plain", "kind": "tile", "props": ["label": "Plain"], "place": ["at": [300, 0]]],
        ]]
        let dry = try run(["apply", "-", "--dry-run"], on: editor, input: document.compactText).get()
        expectEqual(dry["warnings"], [["key": "t:g", "message": #""t:g": A glossy tile glares."#, "severity": "error", "attribute": "finish"]])
        expect(answers.asking.isEmpty && answers.answered.isEmpty, "nothing committed, nothing asked")
        let real = try run(["apply", "-"], on: editor, input: document.compactText).get()
        expectEqual(real["warnings"], [
            ["key": "t:g", "message": #""t:g": A glossy tile glares."#, "severity": "error", "attribute": "finish"],
            ["key": "t:g", "message": #""t:g": it answered late"#, "severity": "error", "attribute": "finish"],
        ])
        expect(!real.compactText.contains("aftermath"))
        let again = try run(["apply", "-"], on: editor, input: document.compactText).get()
        expectEqual(messages(again), [#""t:g": A glossy tile glares."#, #""t:g": it answered late"#], "drawn again, a document says every issue its shapes have, as it always has")
    },
    test("a run with no check, or with nothing to look at, answers at once") {
        let editor = try drawEditor()
        let result = try drawn(#"tile "Plain""#, on: editor)
        expectEqual(result["warnings"], [])
        let answers = Answers()
        let checked = try lateEditor(answers)
        let none = try drawn(#"tile "Plain""#, on: checked)
        expectEqual(none["warnings"], [])
        expect(answers.asking.isEmpty)
    },
])
