import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import DetailPanel
import DecisionModels
import Draw
import Foundation
import LanguageModels
import LanguageRules
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types
import Validation

// Rules on types in the product: written with draw, held through a schema drawn again, checked on real notes as the
// app checks them, and never asked about where nothing would show the answer.

private let rule = "The description mentions no damage or wear."

/// A schema of no fields holding `rules`, as draw's `schema:` writes it: JSON inside a quoted string.
private func drawnSchema(_ rules: [String]) -> String {
    let listed = rules.map { #"{\"says\": \"\#($0)\"}"# }.joined(separator: ", ")
    return rules.isEmpty ? #""{\"type\": \"object\", \"properties\": {}}""#
        : #""{\"type\": \"object\", \"properties\": {\"$rules\": {\"const\": [\#(listed)]}}}""#
}

@MainActor private func run(_ script: String, in editor: CanvasEditor) throws {
    _ = try draw(script: script, dryRun: false, reveal: false, program: "test", in: editor)
}

@MainActor private func shape(called title: String, in editor: CanvasEditor) throws -> AnyShapeRecord {
    try require(editor.document.shapes.first { $0[TitleProperty.self] == title })
}

/// A rule's walk in the shipped window, for the list's tests: Listing (one rule, a `make` field) and its listings, each
/// flagged. With `boards` the last two are on a subboard Texas's board, else all four are on the root.
@MainActor struct ListWalk {
    let w: InspectorWindow
    let listing: ShapeID, mustang: ShapeID, corolla: ShapeID, camry: ShapeID, civic: ShapeID
    let texas: BoardID
    let key: RuleKey
    /// The file once the listings are drawn and checked.
    let start: CanvasFile

    var editor: CanvasEditor { w.editor }
    var walk: IssueWalk { editor.issueWalk! }
    /// The panel's lists, the walk's list among them.
    var table: NSTableView? { w.tables.first }

    init(boards: Bool = true) throws {
        let decisions = ScriptedDecisionModel()
        decisions.fallback = { _ in .success(DecisionAnswers(model: "scripted", yes: ["all": 0.1, "r0": 0.9])) }
        w = try InspectorWindow(decisions: decisions)
        let editor = w.editor
        editor.ruleChecks?.today = { "2026-10-29" }
        let listed = #""{\"type\": \"object\", \"properties\": {\"$rules\": {\"const\": [{\"says\": \"\#(rule)\"}]}, \"make\": {\"type\": \"string\"}}}""#
        let camryPlace = boards ? #"in "Texas""# : #"right of "Corolla""#
        let civicPlace = boards ? #"in "Texas" right of "Camry""# : #"right of "Camry""#
        try run("""
        sticky-note "Listing" text: "A car for sale, described by its seller." schema: \(listed)
        sticky-note "Mustang" right of "Listing" is: "Listing" text: "Some surface rust, a dent in the trunk." fieldValues: {"make": "Ford"}
        sticky-note "Corolla" right of "Mustang" is: "Listing" text: "Dented all over." fieldValues: {"make": "Toyota"}
        subboard "Texas" below "Listing"
        """, in: editor)
        try run("""
        sticky-note "Camry" \(camryPlace) is: "Listing" text: "Rusty." fieldValues: {"make": "Toyota"}
        sticky-note "Civic" \(civicPlace) is: "Listing" text: "Dented." fieldValues: {"make": "Honda"}
        """, in: editor)
        listing = try shape(called: "Listing", in: editor).id
        mustang = try shape(called: "Mustang", in: editor).id
        corolla = try shape(called: "Corolla", in: editor).id
        let made = BoardID(owner: try shape(called: "Texas", in: editor).id)
        texas = made
        // The shapes of a subboard's board are in the file, not the board shown.
        let there = editor.file[boards ? made : .root].shapes
        camry = try require(there.first { $0[TitleProperty.self] == "Camry" }, "Camry in the file").id
        civic = try require(there.first { $0[TitleProperty.self] == "Civic" }, "Civic in the file").id
        let flagging = RuleKey(type: listing, says: rule)
        key = flagging
        let checks = try require(editor.ruleChecks)
        w.window.spin { checks.flagged(by: flagging).count == 4 && !checks.isBusy }
        start = editor.file
    }

    /// More shapes drawn on the board, and the rule's flags waited for until it flags `flagged` shapes.
    func draw(_ script: String, flagged: Int) throws {
        try run(script, in: editor)
        let checks = try require(editor.ruleChecks)
        w.window.spin { checks.flagged(by: key).count == flagged && !checks.isBusy }
    }

    /// The rule's walk at its first stop (or `entry`), and the four stops read.
    func begin(at entry: IssueEntry = .first, stops: Int = 4) throws {
        let scope = try require(editor.registry.issueScope(for: key.source, in: editor))
        walk.begin(scope, at: entry)
        w.window.spin { walk.isRunning && walk.rows.count == stops }
    }
}

@MainActor let languageRulesShippedTests = Suite("Language rules, shipped", [
    test("draw writes $rules in a type's schema, a schema drawn again without them keeps them, and a note of the type is checked and warned about") {
        let decisions = ScriptedDecisionModel()
        decisions.fallback = { request in .success(DecisionAnswers(model: "scripted", yes: ["all": 0.1, "r0": 0.9])) }
        let scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, model: ScriptedLanguageModel(), decisionModel: decisions)
        editor.ruleChecks?.today = { "2026-10-29" }
        try run("""
        sticky-note "Listing" text: "A car for sale, described by its seller." schema: \(drawnSchema([rule]))
        sticky-note "1967 Ford Mustang Coupe" right of "Listing" is: "Listing" text: "Some surface rust, a dent in the trunk."
        """, in: editor)
        let listing = try shape(called: "Listing", in: editor)
        expectEqual(RuleBook.rules(inSchema: try require(listing[TypeSchemaProperty.self]).text), [Rule(says: rule)])
        try run("sticky-note \"Listing\" schema: \(drawnSchema([]))", in: editor)
        expectEqual(RuleBook.rules(inSchema: try require(try shape(called: "Listing", in: editor)[TypeSchemaProperty.self]).text), [Rule(says: rule)],
                    "a schema written whole keeps the rules it doesn't say")
        scheduler.advance(by: .zero)
        scheduler.advance(by: RuleChecks.quiet)
        spinRunLoop(until: { editor.ruleChecks?.isBusy == false })
        let mustang = try shape(called: "1967 Ford Mustang Coupe", in: editor)
        expectEqual(editor.validation?.result(for: mustang.id)?.issues.map(\.message), [rule])
        expectEqual(editor.validation?.result(for: mustang.id)?.worst, .warning, "an orange ring, never red")
        let sent = try require(decisions.lastRequest)
        expectEqual(sent.state["shape"]?["kind"], "note")
        expectEqual(sent.state["shape"]?["words"], "Some surface rust, a dent in the trunk.")
        expectEqual(sent.preface?.contains("These rules come from the listing's types"), true, "the product's words, from its own file")
        let panel = try require(editor.detailPanel)
        let issues = try panel.layout(for: require(editor.document[mustang.id]))
        expectEqual(issues.statuses(in: .of(IssuesTab.self)).map(\.text), [rule])
        expectEqual(issues.statuses(in: .of(IssuesTab.self)).first?.actions.map(\.title), ["Ignore", "Show Rule", "1 of 1"], "and where the rule's walk begins")
        expectEqual(issues.sections(in: .of(IssuesTab.self)).map(\.section), ["rules"], "the rules read together, and Shown")
        expectEqual(try panel.layout(for: require(editor.document[listing.id])).sections(in: .of(RulesTab.self)).map(\.section), ["rules"], "the type's Rules tab")
    },
    test("a rule's warnings are a walk in the product: the scope is found by the warning's source, the stops are the shapes it flags, and Next Issue steps them") {
        let decisions = ScriptedDecisionModel()
        decisions.fallback = { request in .success(DecisionAnswers(model: "scripted", yes: request.state["shape"]?["words"] == "Fixed words." ? ["all": 0.9, "r0": 0.1] : ["all": 0.1, "r0": 0.9])) }
        let scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, model: ScriptedLanguageModel(), decisionModel: decisions)
        editor.ruleChecks?.today = { "2026-10-29" }
        try run("""
        sticky-note "Listing" text: "A car for sale, described by its seller." schema: \(drawnSchema([rule]))
        sticky-note "Mustang" right of "Listing" is: "Listing" text: "Some surface rust, a dent in the trunk."
        sticky-note "Corolla" right of "Mustang" is: "Listing" text: "Dented all over."
        """, in: editor)
        scheduler.advance(by: .zero)
        scheduler.advance(by: RuleChecks.quiet)
        spinRunLoop(until: { editor.ruleChecks?.isBusy == false })
        let listing = try shape(called: "Listing", in: editor).id, mustang = try shape(called: "Mustang", in: editor).id
        let corolla = try shape(called: "Corolla", in: editor).id
        let key = RuleKey(type: listing, says: rule)
        let scope = try require(editor.registry.issueScope(for: key.source, in: editor))
        let chip = IssueScopeChip("Listing", swatch: try require(editor.types).look(of: listing).swatch)
        expectEqual(scope.label(editor), IssueScopeLabel("Rule 1", owner: listing, spoken: "Rule 1 of Listing", chip: chip), "beside the type's chip, in its color")
        let walk = try require(editor.issueWalk)
        walk.begin(scope, at: .first)
        expectEqual(walk.rows.map(\.shape), [mustang, corolla])
        expectEqual(editor.selectedShapeIDs, [mustang])
        expect(editor.perform(.nextIssue))
        expectEqual(editor.selectedShapeIDs, [corolla])
        expect(editor.canPerform(.ignoreIssue), "the warning's Ignore, by its role")
        expect(editor.perform(.ignoreIssue))
        expectEqual(walk.rows.map(\.state), [.open, .ignored])
        expectEqual(walk.total, 1)
        expect(editor.perform(.endIssueWalk))
        expect(!walk.isRunning)
        // No walk, nothing selected: Next Issue begins All Issues (the shipped queries answer it) at the first stop.
        editor.selectedShapeIDs = []
        expect(editor.perform(.nextIssue))
        spinRunLoop(until: { !walk.isGathering })
        expect(walk.isRunning)
        expectEqual(walk.scope?.label(editor), IssueScopeLabel("All Issues"))
        expectEqual(editor.selectedShapeIDs, [mustang], "the first stop in board order")
        // An All Issues walk asks the rule's owner why an issue is gone: an ignore written any way (Ignore Rule ▸ calls the writer)
        // reads ignored, also redone; a rule's walk is not what says so.
        let state = { walk.rows.first { $0.shape == mustang }?.state }
        expectEqual(state(), .open)
        expect(editor.ruleWriter?.ignore(rule, on: mustang) == true)
        expectEqual(state(), .ignored, "set aside by the rule's owner's word, not by an Ignore the walk ran")
        editor.undo()
        expectEqual(state(), .open)
        editor.redo()
        expectEqual(state(), .ignored, "and a redo of it")
        editor.undo()
        expectEqual(state(), .open)
        // Ignore Rule ▸ from the shape's menu is an ignore.
        editor.selectedShapeIDs = [mustang]
        try require(editor.menuForSelection(omitting: [])).choose("Ignore Rule", rule.count <= 60 ? rule : String(rule.prefix(59)) + "…")
        expectEqual(state(), .ignored, "Ignore Rule from the shape's menu")
        editor.undo()
        expectEqual(state(), .open)
        // A fix: the shape's words change so the model no longer flags it; nothing was set aside.
        editor.transact("Reword") { $0.update(mustang, as: StickyNote.self) { $0.props.text = MentionText(plain: "Fixed words.") } }
        scheduler.advance(by: .zero)
        scheduler.advance(by: RuleChecks.quiet)
        spinRunLoop(until: { editor.ruleChecks?.isBusy == false })
        spinRunLoop(until: { !walk.isGathering })
        scheduler.advance(by: .zero)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        expectEqual(state(), .holds, "a fix reads holds")
        expect(editor.perform(.endIssueWalk))
    },
    test("a rule's count begins its walk in the window: the band reads Rule 1 beside the type's chip, › and ‹ step it, a flagged note's line says its place and begins the walk at it, Done ends it") {
        let decisions = ScriptedDecisionModel()
        decisions.fallback = { _ in .success(DecisionAnswers(model: "scripted", yes: ["all": 0.1, "r0": 0.9])) }
        let w = try InspectorWindow(decisions: decisions)
        let editor = w.editor
        editor.ruleChecks?.today = { "2026-10-29" }
        try run("""
        sticky-note "Listing" text: "A car for sale, described by its seller." schema: \(drawnSchema([rule]))
        sticky-note "Mustang" right of "Listing" is: "Listing" text: "Some surface rust, a dent in the trunk."
        sticky-note "Corolla" right of "Mustang" is: "Listing" text: "Dented all over."
        """, in: editor)
        let listing = try shape(called: "Listing", in: editor), mustang = try shape(called: "Mustang", in: editor).id
        let corolla = try shape(called: "Corolla", in: editor).id
        let key = RuleKey(type: listing.id, says: rule)
        let checks = try require(editor.ruleChecks), walk = try require(editor.issueWalk)
        w.window.spin { checks.flagged(by: key).count == 2 && !checks.isBusy }
        // The band's buttons: ‹, the count, › and Done, in the strip at the panel's top (the header's back button is left of them).
        var band: [NSButton] {
            w.host.descendants(NSButton.self).filter { $0.convert($0.bounds, to: w.host).maxY <= 36 && $0.convert($0.bounds, to: w.host).minX > 60 }
                .sorted { $0.convert($0.bounds, to: w.host).minX < $1.convert($1.bounds, to: w.host).minX }
        }
        editor.detailPanel?.choose(.of(RulesTab.self), for: listing.kind)
        editor.selectedShapeIDs = [listing.id]
        w.window.spin { !w.buttons.isEmpty }
        // The one button of the type's Rules tab: the count.
        try require(w.buttons.first).performClick(nil)
        w.window.spin { walk.isRunning && band.count == 4 }
        let label = try require(walk.scope?.label(editor))
        expectEqual(label.title, "Rule 1")
        expectEqual(label.chip, IssueScopeChip("Listing", swatch: try require(editor.types).look(of: listing.id).swatch), "the type's chip, in its color")
        expectEqual(walk.currentRow?.shape, mustang, "the rule's first stop")
        expectEqual(editor.selectedShapeIDs, [mustang], "the count no longer selects every shape it counts")
        expectEqual([walk.number, walk.total], [1, 2])
        band[2].performClick(nil)
        w.window.spin { walk.currentRow?.shape == corolla }
        expectEqual(walk.number, 2)
        band[0].performClick(nil)
        w.window.spin { walk.currentRow?.shape == mustang }
        band[3].performClick(nil)
        w.window.spin { !walk.isRunning }
        // With no walk, a flagged note's line says its place and begins the rule's walk at it.
        editor.selectedShapeIDs = [corolla]
        w.window.settle()
        let layout = try require(editor.detailPanel).layout(for: require(editor.document[corolla]))
        let line = try require(layout.statuses(in: .of(IssuesTab.self)).first)
        expectEqual(line.actions.map(\.title), ["Ignore", "Show Rule", "2 of 2"])
        line.actions[2].perform()
        w.window.spin { walk.isRunning }
        expectEqual(walk.currentRow?.shape, corolla, "begun at this note")
        expectEqual(walk.number, 2)
        expectEqual(walk.scope?.label(editor)?.title, "Rule 1")
        expect(editor.perform(.endIssueWalk))
        expect(!walk.isRunning)
    },
    test("the list in a rule's walk: Issue List opens it over the stop's evidence, rows end in their first value from Types, heads are the boards, Return closes it on the stop with the band staying, and with no walk it begins All Issues with the list open") {
        let scene = try ListWalk()
        let w = scene.w, editor = scene.editor, walk = scene.walk
        let (mustang, corolla, camry, civic, texas) = (scene.mustang, scene.corolla, scene.camry, scene.civic, scene.texas)
        try scene.begin()
        var band: [NSButton] {
            w.host.descendants(NSButton.self).filter { $0.convert($0.bounds, to: w.host).maxY <= 36 && $0.convert($0.bounds, to: w.host).minX > 60 }
        }
        expect(!walk.isListOpen)
        // Go › Issue List opens the list of the walk running, over the stop's evidence.
        expect(editor.canPerform(.issueList))
        expect(editor.perform(.issueList))
        expect(walk.isListOpen)
        w.window.spin { w.tables.first.map { $0.numberOfRows > 0 } == true }
        // Two boards, their heads the boards' names, every one folded but the current stop's: Texas's head and the root's rows.
        expectEqual(walk.boards.map(\.board), [.root, texas])
        expectEqual(walk.boards.map(\.open), [2, 2])
        expectEqual(editor.boardHeading(of: texas).title, "Texas")
        expectEqual(w.tables.first?.numberOfRows, 4, "two heads and the root's two rows")
        // A row ends in its first value, which Types gives the note.
        expectEqual(walk.rows.map { walk.line(of: $0).detail }, ["Ford", "Toyota", "Toyota", "Honda"], "each listing's first value")
        expectEqual(walk.rows.map(\.shape), [mustang, corolla, camry, civic])
        // The evidence under it is the stop's Issues tab: the line's Ignore and Show Rule, the rules read together and Shown.
        let evidence = try require(editor.detailPanel).layout(for: require(editor.document[mustang]))
        let line = try require(evidence.statuses(in: .of(IssuesTab.self)).first)
        expectEqual(line.text, rule)
        expectEqual(line.actions.map(\.title), ["Ignore", "Show Rule"], "the current stop's line says no place: the band does")
        expectEqual(evidence.sections(in: .of(IssuesTab.self)).map(\.section), ["rules"], "LanguageRules' Rules section, with Shown")
        w.window.spin { w.host.descendants(NSButton.self).filter { b in !(w.tables.first.map { b.isDescendant(of: $0) } ?? false) && b.convert(b.bounds, to: w.host).maxY > 40 }.count >= 2 }
        let under = w.host.descendants(NSButton.self).filter { b in !(w.tables.first.map { b.isDescendant(of: $0) } ?? false) && b.convert(b.bounds, to: w.host).maxY > 40 }
        expect(under.count >= 2, "the stop's Ignore and Show Rule are under the list: \(under.count) buttons")
        // The band stays over the list.
        expectEqual(band.count, 4)
        // A step reaches Texas: its rows are unfolded and the root's, which the walk had opened, fold; the evidence follows.
        walk.step(forward: true)
        walk.step(forward: true)
        expectEqual(walk.currentRow?.shape, camry)
        // The highlight, which was on the root's first row (line 1), is on Texas's first row (line 2, under the root's head and Texas's)
        // only once Texas is unfolded and the root's rows are gone.
        w.window.spin { w.tables.first?.selectedRow == 2 }
        expectEqual(w.tables.first?.selectedRow, 2, "the highlight is on the current stop's row, the first under Texas's head")
        expectEqual(w.tables.first?.numberOfRows, 4, "Texas unfolds as the walk reaches it and the root folds as it leaves: two heads and Texas's two rows")
        // Return closes the list on the stop with the band staying, the walk going on.
        w.window.spin { w.tables.first.map { w.window.firstResponder === $0 } == true }
        w.window.press(.return)
        w.window.spin { !walk.isListOpen }
        expect(!walk.isListOpen, "Return closes the list")
        expect(walk.isRunning)
        expectEqual(walk.currentRow?.shape, camry, "on the current stop")
        expectEqual(editor.selectedShapeIDs, [camry])
        expect(band.count >= 4 && walk.isRunning, "the band stays over the shape's own panel: \(band.count) buttons")
        // The same command closes and opens it again; Done ends the walk.
        expect(editor.perform(.issueList))
        expect(walk.isListOpen)
        expect(editor.perform(.issueList))
        expect(!walk.isListOpen)
        expect(editor.perform(.endIssueWalk))
        expect(!walk.isRunning)
        // With no walk, Issue List begins every issue and opens the list.
        editor.selectedShapeIDs = []
        expect(editor.perform(.issueList))
        w.window.spin { walk.isRunning && !walk.isGathering }
        expect(walk.isRunning)
        expect(walk.isListOpen, "begun with the list open")
        expectEqual(walk.scope?.label(editor), IssueScopeLabel("All Issues"))
        expectEqual(editor.selectedShapeIDs, [mustang], "the first stop in board order")
        expect(editor.perform(.endIssueWalk))
    },
    test("under the list: Show Rule gives the panel to the rule's type with the band kept and ⌘' goes on, and an Ignore leaves its row dimmed and reading ignored") {
        let scene = try ListWalk()
        let w = scene.w, editor = scene.editor, walk = scene.walk
        let (mustang, corolla, listing) = (scene.mustang, scene.corolla, scene.listing)
        try scene.begin()
        expect(editor.perform(.issueList))
        w.window.spin { w.tables.first.map { $0.numberOfRows > 0 } == true }
        // Ignore on the current stop, with the list open: its row stays, dimmed, reading ignored; the evidence follows the walk.
        let first = try require(walk.rows.first { $0.shape == mustang })
        expect(!walk.line(of: first).isDimmed)
        expect(editor.perform(.ignoreIssue))
        w.window.spin { walk.rows.first { $0.shape == mustang }?.state == .ignored }
        let ignored = try require(walk.rows.first { $0.shape == mustang })
        expectEqual(ignored.state, .ignored)
        expectEqual(walk.line(of: ignored).detail, "ignored")
        expect(walk.line(of: ignored).isDimmed, "the ignored row is dimmed")
        expect(walk.isListOpen, "and the list stays")
        // Show Rule on the current stop's line: the rule's type is selected and the list gives way, the band kept.
        walk.step(forward: true)
        expectEqual(walk.currentRow?.shape, corolla)
        let evidence = try require(editor.detailPanel).layout(for: require(editor.document[corolla]))
        let line = try require(evidence.statuses(in: .of(IssuesTab.self)).first)
        let show = try require(line.actions.first { $0.title == "Show Rule" })
        show.perform()
        w.window.spin { !walk.isListOpen }
        expect(!walk.isListOpen, "Show Rule closes the list")
        expect(walk.isRunning, "the walk goes on")
        expectEqual(editor.selectedShapeIDs, [listing], "the rule's type is selected")
        w.window.spin { w.host.descendants(NSButton.self).filter { $0.convert($0.bounds, to: w.host).maxY <= 36 && $0.convert($0.bounds, to: w.host).minX > 60 }.count >= 4 }
        expect(w.host.descendants(NSButton.self).filter { $0.convert($0.bounds, to: w.host).maxY <= 36 && $0.convert($0.bounds, to: w.host).minX > 60 }.count >= 4, "the band is kept")
        // ⌘' comes back to the walk, from its place.
        expect(editor.perform(.nextIssue))
        expectEqual(walk.currentRow?.shape, scene.camry, "the stop after the Corolla")
        expectEqual(editor.selectedShapeIDs, [scene.camry], "and it is selected")
        expect(editor.perform(.endIssueWalk))
    },
    test("the rules' light yields to the walk's: with the keyboard in the band only the walk's stops are lit, and with it on the canvas the rules' shapes show") {
        let decisions = ScriptedDecisionModel()
        decisions.fallback = { _ in .success(DecisionAnswers(model: "scripted", yes: ["all": 0.1, "r0": 0.9])) }
        let w = try InspectorWindow(decisions: decisions)
        let editor = w.editor
        editor.ruleChecks?.today = { "2026-10-29" }
        try run("""
        sticky-note "Listing" text: "A car for sale, described by its seller." schema: \(drawnSchema([rule]))
        sticky-note "Mustang" right of "Listing" is: "Listing" text: "Some surface rust, a dent in the trunk."
        sticky-note "Corolla" right of "Mustang" is: "Listing" text: "Dented all over."
        """, in: editor)
        let listing = try shape(called: "Listing", in: editor).id, mustang = try shape(called: "Mustang", in: editor).id
        let corolla = try shape(called: "Corolla", in: editor).id
        let key = RuleKey(type: listing, says: rule)
        let checks = try require(editor.ruleChecks), walk = try require(editor.issueWalk)
        w.window.spin { checks.flagged(by: key).count == 2 && !checks.isBusy }
        let scope = try require(editor.registry.issueScope(for: key.source, in: editor))
        walk.begin(scope, at: .first)
        var band: [NSButton] {
            w.host.descendants(NSButton.self).filter { $0.convert($0.bounds, to: w.host).maxY <= 36 && $0.convert($0.bounds, to: w.host).minX > 60 }
                .sorted { $0.convert($0.bounds, to: w.host).minX < $1.convert($1.bounds, to: w.host).minX }
        }
        w.window.spin { walk.isRunning && band.count == 4 }
        expectEqual(walk.currentRow?.shape, mustang)
        // A pointer over the rule's count lights both its shapes...
        editor.ruleLights?.light([mustang, corolla], by: "Rules")
        expectEqual(editor.outlines.tinted.flatMap(\.shapes), [mustang, corolla], "the keyboard on the canvas: the rules' light shows")
        // ...until the keyboard is in the band: then the walk's light is the only one, on the stop that is not current.
        expect(w.window.makeFirstResponder(band[2]), "the keyboard in the band")
        w.window.spin { editor.issueLights?.isLit == true }
        expectEqual(editor.issueLights?.isLit, true)
        expectEqual(editor.outlines.tinted.flatMap(\.shapes), [corolla], "the walk's light alone: the rules' yields")
        // The keyboard back on the canvas: the walk's goes and the rules' shows again.
        w.window.makeFirstResponder(w.canvas)
        w.window.spin { editor.issueLights?.isLit == false }
        expectEqual(editor.outlines.tinted.flatMap(\.shapes), [mustang, corolla], "and the rules' light is back")
        editor.ruleLights?.light(nil, by: "Rules")
        expect(editor.perform(.endIssueWalk))
    },
    test("an agent's draw is checked the next turn, while a person's edit waits for the file to be quiet") {
        let decisions = ScriptedDecisionModel()
        decisions.answerAll(0.2)
        let scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, model: ScriptedLanguageModel(), decisionModel: decisions)
        scheduler.advance(by: .zero)
        try run("""
        sticky-note "Listing" schema: \(drawnSchema([rule]))
        sticky-note "Corolla" right of "Listing" is: "Listing" text: "Barely driven."
        """, in: editor)
        scheduler.advance(by: .zero)
        spinRunLoop(until: { editor.ruleChecks?.isBusy == false })
        expectEqual(decisions.requests.count, 1, "no quiet waited for")
        let corolla = try shape(called: "Corolla", in: editor).id
        editor.transact("Title") { $0.update(corolla) { $0[TitleProperty.self] = "2021 Corolla" } }
        scheduler.advance(by: .zero)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        expectEqual(decisions.requests.count, 1, "a person may still be typing")
        scheduler.advance(by: RuleChecks.quiet)
        spinRunLoop(until: { editor.ruleChecks?.isBusy == false })
        expectEqual(decisions.requests.count, 2)
    },
    test("a note being edited is checked once its editing ends") {
        let decisions = ScriptedDecisionModel()
        decisions.answerAll(0.2)
        let scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, model: ScriptedLanguageModel(), decisionModel: decisions)
        try run("""
        sticky-note "Listing" schema: \(drawnSchema([rule]))
        sticky-note "Corolla" right of "Listing" is: "Listing" text: "Barely driven."
        """, in: editor)
        scheduler.advance(by: .zero)
        scheduler.advance(by: RuleChecks.quiet)
        spinRunLoop(until: { editor.ruleChecks?.isBusy == false })
        expectEqual(decisions.requests.count, 1)
        let corolla = try shape(called: "Corolla", in: editor).id
        expect(editor.beginEditing(corolla), "a note is edited")
        editor.transact("Title") { $0.update(corolla) { $0[TitleProperty.self] = "2021 Corolla" } }
        scheduler.advance(by: RuleChecks.quiet * 3)
        spinRunLoop(until: { editor.ruleChecks?.isBusy == false })
        expectEqual(decisions.requests.count, 1, "nothing asked about a note while it's edited")
        editor.endEditing()
        scheduler.advance(by: .zero)
        spinRunLoop(until: { editor.ruleChecks?.isBusy == false })
        expectEqual(decisions.requests.count, 2, "asked once its editing ended")
    },
    test("a picture of a board, as Quick Look draws one, asks nothing") {
        let decisions = ScriptedDecisionModel()
        decisions.answerAll(0.9)
        let registry = try ShippedPlugins.registry(pasteboard: NSPasteboard.withUniqueName(), model: ScriptedLanguageModel(), decisionModel: decisions)
        let scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, model: ScriptedLanguageModel(), decisionModel: ScriptedDecisionModel())
        try run("""
        sticky-note "Listing" schema: \(drawnSchema([rule]))
        sticky-note "Corolla" right of "Listing" is: "Listing" text: "Barely driven."
        """, in: editor)
        do {
            let picture = BoardPicture(file: editor.file, registry: registry)
            _ = picture.pngData(within: CGSize(width: 400, height: 300), scale: 1, appearance: NSAppearance(named: .aqua)!)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        expectEqual(decisions.requests.count, 0)
    },
    test("what a rule sees of an arrow is the same however the file came to be filed: a file opened again asks nothing it asked today") {
        // Topology files a commit's arrows in no particular order, an edited arrow last, and a file opened again in its
        // boards' order: what a rule sees lists the arrows beside one by the file's own order, so the requests (and the
        // answers kept for them by the day) are the same in every session.
        let decisions = ScriptedDecisionModel()
        decisions.answerAll(0.2)
        let scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, model: ScriptedLanguageModel(), decisionModel: decisions)
        editor.ruleChecks?.today = { "2026-10-29" }
        let vote = #""{\"type\": \"object\", \"properties\": {\"$rules\": {\"const\": [{\"says\": \"In line with the member's record.\"}]}, \"position\": {\"type\": \"string\"}}}""#
        try run("""
        sticky-note "Member" schema: \(drawnSchema([]))
        sticky-note "Bill" right of "Member" (gap: 400) schema: \(drawnSchema([]))
        sticky-note "Vote" right of "Member" relationship: true schema: \(vote)
        edge "Member" -> "Vote"
        edge "Vote" -> "Bill"
        sticky-note "Ann" below "Member" (gap: 200) is: "Member"
        sticky-note "C bill" below "Bill" (gap: 200) is: "Bill"
        sticky-note "A bill" below "C bill" is: "Bill"
        sticky-note "B bill" below "A bill" is: "Bill"
        edge "Ann" -> "C bill" is: "Vote" fieldValues: {"position": "Yea"}
        edge "Ann" -> "A bill" is: "Vote" fieldValues: {"position": "Yea"}
        edge "Ann" -> "B bill" is: "Vote" fieldValues: {"position": "Nay"}
        """, in: editor)
        // An edit, and its undoing by another: the arrow is filed again, last, with the values it had.
        try run(#"edge "Ann" -> "C bill" is: "Vote" fieldValues: {"position": "Nay"}"#, in: editor)
        try run(#"edge "Ann" -> "C bill" is: "Vote" fieldValues: {"position": "Yea"}"#, in: editor)
        let checks = try require(editor.ruleChecks)
        let arrow = try require(editor.document.shapes.first { $0[FieldValuesProperty.self]?.values["position"] == .string("Nay") }, "the vote on B bill")
        let before = try awaitResult { await checks.states(of: [arrow.id]) }[arrow.id]
        let others = before?["beside it at its start (other Vote arrows at Ann)"]?.arrayValue?.compactMap { $0["to"]?["title"]?.stringValue }
        expectEqual(others, ["A bill", "C bill"], "by the far end's name, not the order they were filed in")
        // The file opened again: another editor over the same shapes, which files them afresh, in the board's order.
        let reopened = ShippedPlugins.makeEditor(document: editor.document, scheduler: ManualScheduler(), model: ScriptedLanguageModel(), decisionModel: decisions)
        reopened.ruleChecks?.today = { "2026-10-29" }
        let checksAgain = try require(reopened.ruleChecks)
        let after = try awaitResult { await checksAgain.states(of: [arrow.id]) }[arrow.id]
        expectEqual(after, before, "the same state in a file opened again, so the same request and the answer kept for it")
    },
])
