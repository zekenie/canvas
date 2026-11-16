import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import DetailPanel
import LanguageModels
import Selection
import SlashCommands
import TestKit
import Titles
import Validation

// What the Rules tab and the bar say where a constraint can't be added or a shape breaks several: words a list already holds
// (said, with nothing asked), a holder that says why it can't take a list, and a shape that breaks several constraints of a place
// (the first one's words and how many more).

private let penRect = CGRect(x: 100, y: 100, width: 400, height: 300)

@MainActor let wordsTests = Suite("Constraints: what is said of words that can't be added", [
    test("words typed in the add box that its list holds already stay there with a line saying so: nothing is asked, nothing written; Escape lets them go") {
        let model = ScriptedLanguageModel(answers: ["tile[finish=\"glossy\"]"])
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect, [onlyTiles])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 3 }
        let boxes = try require(h.editor.constraintBoxes)
        let adding = ConstraintBox(holder: pen, constraint: nil)
        let revision = h.editor.revision
        panel.type("only  tiles", in: panel.boxes[2])
        panel.land()
        expectEqual(boxes.status(of: adding), .held("Pen already accepts only tiles."))
        expectEqual(boxes.text(of: adding), "only  tiles", "the words stay")
        h.scheduler.advance(by: .milliseconds(700))
        panel.land()
        expectEqual(boxes.status(of: adding), .held("Pen already accepts only tiles."), "still there once the words have rested")
        expectEqual(model.requests.count, 0, "the model is never asked")
        expectEqual(h.editor.revision, revision, "nothing written, no step")
        panel.window.makeFirstResponder(panel.boxes[2])
        panel.window.pressEscape()
        panel.window.settle()
        expect(!boxes.hasDraft(adding), "Escape lets them go")
        expectEqual(boxes.status(of: adding), .none)
        panel.type("only glossy tiles", in: panel.boxes[2])
        panel.land(after: model, answers: 1)
        let says: [String] = h.list(of: pen).map { $0.says }
        expectEqual(says, ["only tiles", "only glossy tiles"], "other words are asked as ever")
    },
    test("a holder with no reason of its own: the panel says Constraints' words under the box, and keeps saying them, since it can't tell when the list can be taken") {
        let given = Given()
        given.noReason = true
        let h = try constraintHarness(given, log: RefusalLog(), model: ScriptedLanguageModel())
        let draft = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint", list: "not json yet"))
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(draft)
        panel.window.spin { panel.boxes.count == 1 }
        let boxes = try require(h.editor.constraintBoxes)
        let adding = ConstraintBox(holder: draft, constraint: nil)
        panel.type("tile", in: panel.boxes[0])
        panel.land()
        expectEqual(boxes.status(of: adding), .refused("Can't add a constraint to Sprint."), "no reason of its own: Constraints' words")
        h.editor.transact("Fix") { $0.update(inFile: draft, as: Charter.self) { $0.props.list = "[]" } }
        panel.land()
        expectEqual(boxes.status(of: adding), .refused("Can't add a constraint to Sprint."), "nothing says it can take one now")
    },
    test("a holder that says why it can't take a list: the panel shows it under the add box while the words wait there, the bar and VoiceOver say it") {
        let given = Given()
        let log = RefusalLog()
        let h = try constraintHarness(given, log: log, model: ScriptedLanguageModel())
        let draft = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint", list: "not json yet"))
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(draft)
        panel.window.spin { panel.boxes.count == 1 }
        let boxes = try require(h.editor.constraintBoxes)
        let adding = ConstraintBox(holder: draft, constraint: nil)
        given.whyNot = { (name: String) -> String in name + "'s list isn't JSON yet." }
        panel.type("tile", in: panel.boxes[0])
        panel.land()
        let said: ConstraintBoxStatus = .refused("Sprint's list isn't JSON yet.")
        expectEqual(boxes.status(of: adding), said, "the holder's own, under the box")
        expectEqual(boxes.text(of: adding), "tile", "the words wait in the box")
        let answer = try h.constrain("tile", on: .selection([draft]))
        expectEqual(answer, SlashAnswer.failed("Sprint's list isn't JSON yet."), "and in the bar")
        panel.window.makeFirstResponder(panel.boxes[0])
        panel.window.pressReturn()
        panel.land()
        expectEqual(h.editor.announcements.last, "Sprint's list isn't JSON yet.", "and to VoiceOver, as the words are committed again")
        h.editor.transact("Fix") { $0.update(inFile: draft, as: Charter.self) { $0.props.list = "[]" } }
        panel.land()
        let revision = h.editor.revision
        let fixed: ConstraintBoxStatus = boxes.status(of: adding)
        var refusing = false
        if case .refused = fixed { refusing = true }
        expect(!refusing, "the holder can take a list now: no line under the box (\(fixed))")
        expectEqual(boxes.text(of: adding), "tile", "the words wait in the box")
        expectEqual(h.list(of: draft), [], "nothing asked or written until Return")
        expectEqual(h.editor.revision, revision, "and no step")
        panel.window.makeFirstResponder(panel.boxes[0])
        panel.window.pressReturn()
        panel.land()
        expectEqual(boxes.status(of: adding), ConstraintBoxStatus.none, "written once the list can take it")
        expectEqual(h.list(of: draft), [Constraint(says: "tile", query: "tile")])
    },
    test("words typed in a corral's add box, the corral frozen before the model answers: it shakes, nothing is written, no step, the words stay with the line; thawed, the line goes and the words wait, and Return lands them as Add Constraint") {
        let log = RefusalLog()
        let model = ScriptedLanguageModel(answers: ["tile"])
        model.holdsAnswers = true
        let h = try constraintHarness(log: log, model: model)
        let pen = h.corral("Pen", penRect, [noDiscs])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 3 }
        let boxes = try require(h.editor.constraintBoxes)
        let adding = ConstraintBox(holder: pen, constraint: nil)
        panel.type("only tiles", in: panel.boxes[2])
        h.scheduler.advance(by: .zero)
        panel.window.spin { model.waiting == 1 }
        h.editor.freeze([pen])
        let step = h.editor.undoHistory.undoName, revision = h.editor.revision, said = h.editor.announcements
        log.refusals = []
        model.release()
        panel.land(after: model, answers: 1)
        expectEqual(log.refusals, [[pen]], "the corral shakes")
        expectEqual(h.list(of: pen), [noDiscs], "nothing is written")
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        expectEqual(Array(h.editor.announcements.dropFirst(said.count)), ["Locked"], "nothing is said beyond the shake's own")
        expectEqual(boxes.text(of: adding), "only tiles", "the words stay in the box")
        expectEqual(boxes.status(of: adding), .refused("Can't add a constraint to Pen."), "with the line")
        expectEqual(model.requests.count, 1)
        h.editor.freeze([pen], false)
        var refusing = false
        if case .refused = boxes.status(of: adding) { refusing = true }
        expect(!refusing, "the corral can change now: the line goes")
        expectEqual(boxes.text(of: adding), "only tiles", "the words wait in the box")
        expectEqual(h.list(of: pen), [noDiscs], "nothing asked or written until Return")
        boxes.commit(adding)
        panel.land()
        expectEqual(h.list(of: pen), [noDiscs, Constraint(says: "only tiles", query: "tile")], "written once it can change")
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint")
        expectEqual(boxes.text(of: adding), "")
        expectEqual(model.requests.count, 1, "the model isn't asked again")
    },
    test("a row's words edited the same way: kept with the line while the corral is frozen, written as Change Constraint once it can change") {
        let log = RefusalLog()
        let model = ScriptedLanguageModel(answers: ["tile[finish=\"glossy\"]"])
        model.holdsAnswers = true
        let h = try constraintHarness(log: log, model: model)
        let reaching = Constraint(says: "only tiles", query: "tile", reach: .descendants)
        let pen = h.corral("Pen", penRect, [reaching])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 3 }
        let boxes = try require(h.editor.constraintBoxes)
        let row = ConstraintBox(holder: pen, constraint: reaching)
        panel.window.makeFirstResponder(panel.boxes[0])
        panel.boxes[0].selectAll(nil)
        panel.window.type("only glossy tiles")
        panel.window.pressReturn()
        h.scheduler.advance(by: .zero)
        panel.window.spin { model.waiting == 1 }
        h.editor.freeze([pen])
        let step = h.editor.undoHistory.undoName
        log.refusals = []
        model.release()
        panel.land(after: model, answers: 1)
        expectEqual(log.refusals, [[pen]], "the corral shakes")
        expectEqual(h.list(of: pen), [reaching], "nothing is written")
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        expectEqual(boxes.text(of: row), "only glossy tiles", "the words stay in the row")
        expectEqual(boxes.status(of: row), .refused("Can't change Pen's constraints."), "with the line")
        h.editor.freeze([pen], false)
        expectEqual(boxes.text(of: row), "only glossy tiles", "the words wait")
        boxes.commit(row)
        panel.land()
        expectEqual(h.list(of: pen), [Constraint(says: "only glossy tiles", query: "tile[finish=\"glossy\"]", reach: .descendants)])
        expectEqual(h.editor.undoHistory.undoName, "Change Constraint")
    },
    test("a shape that breaks several constraints of a place is listed once, with the first one's words and how many more; VoiceOver hears the same") {
        let h = try constraintHarness()
        let several: [Constraint] = [Constraint(says: "only discs", query: "disc"), Constraint(says: "no tiles", query: ":not(tile)"),
                                     Constraint(says: "only urgent things", query: ":urgent")]
        let pen = h.corral("Pen", penRect, several)
        let alpha = h.tile("Alpha", at: CGPoint(x: 150, y: 250), in: pen)
        let disc = h.disc(at: CGPoint(x: 400, y: 330), in: pen)
        h.settle()
        let summary = try require(h.index.breakSummary(of: alpha, in: .shape(pen)))
        expectEqual(summary.says, "only discs")
        expectEqual(summary.more, 2, "it breaks all three")
        let row = ConstraintsStyle.breakDetail(summary.says, more: summary.more)
        expectEqual(row.words, "only discs", "the row: the words")
        expectEqual(row.count, "+2", "and its count, a text of its own")
        expectEqual(ConstraintsStyle.breaks("Alpha", summary.says, more: summary.more), "Alpha, breaks only discs and 2 more", "what VoiceOver hears")
        expectEqual(ConstraintsStyle.breakDetail("only discs", more: 0).words, "only discs", "one: its words alone")
        expect(ConstraintsStyle.breakDetail("only discs", more: 0).count == nil, "and no count")
        let long = String(repeating: "only tiles that are glossy and round ", count: 5)
        expectEqual(ConstraintsStyle.breakDetail(long, more: 1).count, "+1", "long words leave the count as it is: the view cuts the words, never it")
        expectEqual(ConstraintsStyle.breakDetail("no subboards.", more: 1).words, "no subboards", "words written with a full stop go bare")
        expectEqual(ConstraintsStyle.breaks("Alpha", "only tiles.", more: 1), "Alpha, breaks only tiles and 1 more", "bare in what VoiceOver hears: no full stop mid-sentence")
        expectEqual(ConstraintsStyle.breaks("Alpha", "only discs"), "Alpha, breaks only discs")
        expectEqual(h.index.breakSummary(of: disc, in: .shape(pen))?.says, "only urgent things")
        expectEqual(h.index.breakSummary(of: disc, in: .shape(pen))?.more, 0)
        expect(h.index.breakSummary(of: alpha, in: .root) == nil, "none of another place's")
    },
])
