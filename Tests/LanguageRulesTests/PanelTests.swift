import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import DecisionModels
import DetailPanel
import Foundation
import Geometry
import LanguageModels
import LanguageRules
import Mentions
import QueryTranslation
import Selection
import SwiftUI
import TextEditing
import TestKit
import Titles
import Types
import Validation

// Rules in the panel and the menus: the writer under them, a type's Rules tab, a checked shape's Rules section and its
// Issues lines' actions, the counts, the light, the menus that do what the buttons do, and the panel by keys.

@MainActor let ruleWriterTests = Suite("Writing rules", [
    test("a type's rules are written into its schema with the rest of its JSON as typed, one step, Change Rules; none takes the member away") {
        let board = Listings()
        let scene = try RuleScene(board.shapes)
        let writer = try require(scene.editor.ruleWriter)
        let before = try require(scene.editor.document[board.listing]?[TypeSchemaProperty.self]?.text)
        expect(writer.setRules([Rule(says: "One."), Rule(says: "Two \"quoted\".")], of: board.listing))
        let text = try require(scene.editor.document[board.listing]?[TypeSchemaProperty.self]?.text)
        expectEqual(RuleBook.rules(inSchema: text), [Rule(says: "One."), Rule(says: "Two \"quoted\".")])
        expect(text.hasPrefix(#"{"type": "object", "properties": {"$rules": {"const": [{"says": "One."}, {"says": "Two \"quoted\"."}]}"#), text)
        expectEqual(scene.editor.undoHistory.undoName, "Change Rules")
        expect(!writer.setRules([Rule(says: "One."), Rule(says: "Two \"quoted\".")], of: board.listing), "the same rules: nothing written")
        expect(writer.setRules([], of: board.listing))
        expectEqual(scene.editor.document[board.listing]?[TypeSchemaProperty.self]?.text, #"{"type": "object", "properties": {}}"#)
        scene.editor.undo()
        scene.editor.undo()
        expectEqual(scene.editor.document[board.listing]?[TypeSchemaProperty.self]?.text, before)
        expect(!writer.setRules([Rule(says: "On a card that is no type.")], of: board.corolla), "a shape that holds no schema")
    },
    test("a chip's phrase and query are written with its rule") {
        let board = Listings()
        let scene = try RuleScene(board.shapes)
        let rule = Rule(says: "A listing of a car the dealer stocks.", find: [RuleChip(phrase: "the dealer", query: #"card"Dealer""#)])
        expect(try require(scene.editor.ruleWriter).setRules([rule], of: board.listing))
        expectEqual(RuleBook.rules(of: board.listing, in: scene.editor), [rule])
    },
    test("Ignore and Stop Ignoring are one step each, and change what the shape is warned of") {
        let board = Listings()
        let scene = try RuleScene(board.shapes, decisions: answering(["all": 0.1, "r0": 0.9]))
        scene.settle()
        expectEqual(scene.warnings(of: board.corolla), [Listings.agrees])
        let writer = try require(scene.editor.ruleWriter)
        expect(writer.ignore(Listings.agrees, on: board.corolla))
        expectEqual(scene.editor.undoHistory.undoName, "Ignore Rule")
        expectEqual(scene.editor.document[board.corolla]?[IgnoredRulesProperty.self], [Listings.agrees])
        expectEqual(scene.warnings(of: board.corolla), [], "an ignored rule warns of nothing")
        expect(!writer.ignore(Listings.agrees, on: board.corolla), "ignored already")
        expect(writer.stopIgnoring(Listings.agrees, on: board.corolla))
        expectEqual(scene.editor.undoHistory.undoName, "Stop Ignoring Rule")
        expect(scene.editor.document[board.corolla]?[IgnoredRulesProperty.self] == nil, "none left: the property goes")
        expectEqual(scene.warnings(of: board.corolla), [Listings.agrees])
        expect(!writer.ignore(Listings.agrees, on: board.listing), "a type is checked by no rule")
    },
])

/// The answers that flag the Corolla by the first rule alone: read together the rules are broken ("all" is whether they
/// hold), and the first fails.
private let flagsFirst: [String: Double] = ["all": 0.1, "r0": 0.9, "r1": 0.1]

/// A rule's sentence as a menu item says it: cut to a line.
private func cut(_ says: String) -> String { says.count <= 60 ? says : String(says.prefix(59)) + "…" }

@MainActor let rulePanelTests = Suite("Rules in the panel", [
    test("a type's rules on the board: Rules and how many, after its pill and the chips of what it builds on; none without rules, none zoomed out") {
        let board = Listings()
        let scene = try RuleScene(board.shapes)
        @MainActor func frames(of id: ShapeID) -> [AdornmentFrame] { scene.editor.adornmentFrames(of: id) }
        let chip = try require(frames(of: board.listing).first { $0.adornment == .of(RulesChip.self) })
        expectEqual(chip.label.text, "Rules")
        expectEqual(chip.label.count, 2)
        expect(chip.label.tag == nil, "nothing to click: each rule is in the Rules tab")
        let before = frames(of: board.listing).filter { $0.rect.minY == chip.rect.minY && $0.rect.maxX <= chip.rect.minX }
        expectEqual(before.map(\.adornment), [.of(TitlePill.self), .of(TypeChips.self)], "after the type's pill and the chip of Car")
        expect(frames(of: board.car).allSatisfy { $0.adornment != .of(RulesChip.self) }, "a type with no rules of its own has none")
        expect(frames(of: board.corolla).allSatisfy { $0.adornment != .of(RulesChip.self) }, "nor a shape that is no type")
        try require(scene.editor.ruleWriter).setRules([Rule(says: Listings.agrees), Rule(says: Listings.noDamage), Rule(says: "It's in stock.")], of: board.listing)
        expectEqual(frames(of: board.listing).first { $0.adornment == .of(RulesChip.self) }?.label.count, 3, "counted again")
        scene.editor.skeletonZoom = 0.5
        scene.editor.camera = Camera(origin: .zero, zoom: 0.4)
        expect(frames(of: board.listing).isEmpty, "zoomed out: a skeleton has no chip")
    },
    test("a type's panel has a Rules tab after Schema; a shape that is no type has none") {
        let board = Listings()
        let scene = try RuleScene(board.shapes)
        let panel = try require(scene.editor.detailPanel)
        let type = try panel.layout(for: require(scene.editor.document[board.listing]))
        expectEqual(type.tabs.map(\.title).filter { ["Schema", "Rules"].contains($0) }, ["Schema", "Rules"])
        expectEqual(type.sections(in: .of(RulesTab.self)).map(\.section), ["rules"])
        expect(try !panel.layout(for: require(scene.editor.document[board.corolla])).tabs.contains(.of(RulesTab.self)))
    },
    test("a checked shape's Issues tab has the Rules section, flagged or not; a shape no rule checks has none") {
        let board = Listings()
        let plain = card("Plain", of: [], id: ShapeID(), at: CGPoint(x: 600, y: 300))
        let scene = try RuleScene(board.shapes + [plain], decisions: answering(["all": 0.9, "r0": 0.1, "r1": 0.1]))
        scene.settle()
        let panel = try require(scene.editor.detailPanel)
        let checked = try panel.layout(for: require(scene.editor.document[board.corolla]))
        expectEqual(checked.sections(in: .of(IssuesTab.self)).map(\.section), ["rules"])
        expectEqual(checked.statuses(in: .of(IssuesTab.self)), [], "nothing flags it")
        expect(try !panel.layout(for: require(scene.editor.document[plain.id])).tabs.contains(.of(IssuesTab.self)))
    },
    test("the Issues line quotes the rule and offers Ignore and Show Rule: Ignore ignores it in one step, Show Rule selects the type on its Rules tab") {
        let board = Listings()
        let scene = try RuleScene(board.shapes, decisions: answering(flagsFirst))
        scene.settle()
        let panel = try require(scene.editor.detailPanel)
        let lines = try panel.layout(for: require(scene.editor.document[board.corolla])).statuses(in: .of(IssuesTab.self))
        expectEqual(lines.map(\.text), [Listings.agrees])
        let line = try require(lines.first)
        expectEqual(line.actions.map(\.title), ["Ignore", "Show Rule", "1 of 1"], "and where the rule's walk would begin: its place among the shapes it flags")
        line.actions[1].perform()
        scene.scheduler.advance(by: .zero)
        expectEqual(scene.editor.selectedShapeIDs, [board.listing])
        let type = try require(scene.editor.document[board.listing])
        expectEqual(panel.currentTab(in: panel.layout(for: type), for: type.kind), .of(RulesTab.self))
        line.actions[0].perform()
        expectEqual(scene.editor.undoHistory.undoName, "Ignore Rule")
        expectEqual(scene.editor.document[board.corolla]?[IgnoredRulesProperty.self], [Listings.agrees])
        expectEqual(try panel.layout(for: require(scene.editor.document[board.corolla])).statuses(in: .of(IssuesTab.self)), [])
    },
    test("each rule's state: flags, holds, unsure, and ignored; checking while it's marked or asked again, its last answer still warning") {
        let board = Listings()
        let decisions = answering(["all": 0.1, "r0": 0.9, "r1": 0.5])
        let scene = try RuleScene(board.shapes, decisions: decisions)
        let checks = scene.checks
        @MainActor func states() throws -> [RuleState] { try checks.verdicts(of: require(scene.editor.document[board.corolla])).map(\.state) }
        scene.scheduler.advance(by: .zero)
        expectEqual(try states(), [.checking, .checking], "marked as the file opens")
        scene.settle()
        expectEqual(try states(), [.flags, .unsure])
        expectEqual(try checks.verdicts(of: require(scene.editor.document[board.corolla])).map(\.rule.typeName), ["Listing", "Listing"])
        try require(scene.editor.ruleWriter).ignore(Listings.noDamage, on: board.corolla)
        expectEqual(try states(), [.checking, .checking], "a commit to it marks it")
        expectEqual(scene.warnings(of: board.corolla), [Listings.agrees], "its last answer counts while it's asked again")
        scene.settle()
        expectEqual(try states(), [.flags, .ignored], "what it ignores isn't sent: the day's answer, from memory")
        decisions.fallback = { request in
            .success(DecisionAnswers(model: "scripted", yes: Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, 0.9) })))
        }
        scene.editor.transact("Typing") { $0.update(board.corolla, as: Card.self) { $0.props.text = MentionText(plain: "Barely driven.") } }
        scene.settle()
        expectEqual(try states(), [.holds, .ignored], "read together they hold: the rule that flags alone is qualified")
    },
    test("Shown is what the model was shown, group by group, by shape") {
        let board = Listings()
        let scene = try RuleScene(board.shapes, decisions: answering(flagsFirst))
        scene.settle()
        let sent = try require(scene.checks.sent(for: board.corolla))
        expectEqual(sent.groups.map(\.label), ["its types", "in", "beside it, in the same place"])
        expectEqual(sent.groups[0].shapes, [board.listing, board.car])
        expectEqual(sent.groups[1].place, "the board's top level")
        expectEqual(Set(sent.groups[2].shapes), [board.car, board.listing])
        expectEqual(sent.state["shape"]?["title"], "2021 Toyota Corolla LE")
    },
    test("a rule's count is the shapes it flags, less those that ignore it, and follows them as they're checked again") {
        let board = Listings()
        let second = card("2019 Toyota Camry SE", of: [board.listing], at: CGPoint(x: 600, y: 0))
        let scene = try RuleScene(board.shapes + [second], decisions: answering(flagsFirst))
        scene.settle()
        let agrees = RuleKey(type: board.listing, says: Listings.agrees), noDamage = RuleKey(type: board.listing, says: Listings.noDamage)
        expectEqual(scene.checks.flagged(by: agrees), [board.corolla, second.id])
        expectEqual(scene.checks.flagged(by: noDamage), [])
        try require(scene.editor.ruleWriter).ignore(Listings.agrees, on: second.id)
        expectEqual(scene.checks.flagged(by: agrees), [board.corolla], "ignored: out of the count at once")
        scene.editor.undo()
        expectEqual(scene.checks.flagged(by: agrees), [board.corolla, second.id])
        scene.editor.transact("Delete") { $0.delete([second.id]) }
        scene.settle()
        expectEqual(scene.checks.flagged(by: agrees), [board.corolla])
    },
    test("a highlighted count or line lights its shapes in the rules' light; what lit them lets go, and nothing else") {
        let board = Listings()
        let scene = try RuleScene(board.shapes)
        let lights = try require(scene.editor.ruleLights)
        lights.light([board.corolla, board.car], by: "count")
        expectEqual(scene.editor.outlines.tinted.map(\.shapes), [[board.corolla, board.car]])
        lights.light(nil, by: "Shown")
        expectEqual(scene.editor.outlines.tinted.map(\.shapes), [[board.corolla, board.car]], "another's let go lets go of nothing")
        lights.light(nil, by: "count")
        expectEqual(scene.editor.outlines.tinted, [])
        lights.light([board.corolla], by: "count")
        scene.editor.transact("Delete") { $0.delete([board.corolla]) }
        expectEqual(scene.editor.outlines.tinted, [], "a shape gone is lit no more")
    },
    test("a type's menu has Select Flagged with each rule that flags and its count, and a pick selects them") {
        let board = Listings()
        let scene = try RuleScene(board.shapes, decisions: answering(flagsFirst))
        scene.settle()
        scene.editor.selectedShapeIDs = [board.listing]
        var menu = try require(scene.h.secondaryClick(at: CGPoint(x: 100, y: 130)))
        expect(menu.outline.contains("Select Flagged ▸"), "\(menu.outline)")
        expect(menu.outline.contains("  \(cut(Listings.agrees)) (1)"), "\(menu.outline)")
        try menu.choose("Select Flagged", "\(cut(Listings.agrees)) (1)")
        expectEqual(scene.editor.selectedShapeIDs, [board.corolla])
        scene.editor.selectedShapeIDs = [board.car]
        menu = try require(scene.h.secondaryClick(at: CGPoint(x: 100, y: 30)))
        expect(!menu.outline.contains("Select Flagged ▸"), "Car's rules flag nothing: \(menu.outline)")
    },
    test("a type's menu has Walk Flagged beside Select Flagged, in the same form: a pick begins that rule's walk at its first stop") {
        let board = Listings()
        let beetle = card("1972 Beetle", of: [board.listing], id: ShapeID(), at: CGPoint(x: 600, y: 0))
        let scene = try RuleScene(board.shapes + [beetle], decisions: answering(flagsFirst))
        scene.settle()
        let walk = try require(scene.editor.issueWalk)
        scene.editor.selectedShapeIDs = [board.listing]
        var menu = try require(scene.h.secondaryClick(at: CGPoint(x: 100, y: 130)))
        expect(menu.outline.contains("Select Flagged ▸"), "\(menu.outline)")
        expect(menu.outline.contains("Walk Flagged ▸"), "\(menu.outline)")
        expect(menu.outline.contains("  \(cut(Listings.agrees)) (2)"), "each rule that flags, with its count: \(menu.outline)")
        expect(!walk.isRunning)
        try menu.choose("Walk Flagged", "\(cut(Listings.agrees)) (2)")
        scene.scheduler.advance(by: .zero)
        expect(walk.isRunning)
        expectEqual(walk.scope?.label(scene.editor)?.title, "Rule 1")
        expectEqual(walk.currentRow?.shape, board.corolla, "the first stop in board order")
        expectEqual(walk.number, 1)
        expectEqual(walk.total, 2)
        expectEqual(scene.editor.selectedShapeIDs, [board.corolla], "the walk selects its stop alone; Select Flagged ▸ selects them all")
        scene.editor.selectedShapeIDs = [board.car]
        menu = try require(scene.h.secondaryClick(at: CGPoint(x: 100, y: 30)))
        expect(!menu.outline.contains("Walk Flagged"), "Car's rules flag nothing: \(menu.outline)")
    },
    test("a checked shape's menu has Walk Flagged beside Ignore Rule, the rules that flag it: a pick begins that rule's walk at this shape") {
        let board = Listings()
        let beetle = card("1972 Beetle", of: [board.listing], id: ShapeID(), at: CGPoint(x: 600, y: 0))
        let scene = try RuleScene(board.shapes + [beetle], decisions: answering(flagsFirst))
        scene.settle()
        let walk = try require(scene.editor.issueWalk)
        scene.editor.selectedShapeIDs = [beetle.id]
        let menu = try require(scene.h.secondaryClick(at: CGPoint(x: 700, y: 30)))
        expect(menu.outline.contains("Ignore Rule ▸"), "\(menu.outline)")
        expect(menu.outline.contains("Walk Flagged ▸"), "\(menu.outline)")
        expect(menu.outline.contains("  \(cut(Listings.agrees)) (2)"), "\(menu.outline)")
        expect(!menu.outline.contains("  \(cut(Listings.noDamage)) ("), "only the rule that flags it: \(menu.outline)")
        try menu.choose("Walk Flagged", "\(cut(Listings.agrees)) (2)")
        scene.scheduler.advance(by: .zero)
        expect(walk.isRunning)
        expectEqual(walk.currentRow?.shape, beetle.id, "begun at this shape, the rule's second stop")
        expectEqual(walk.number, 2)
        expectEqual(walk.total, 2)
        expectEqual(scene.editor.selectedShapeIDs, [beetle.id])
        // A shape no rule flags has none.
        let quiet = try RuleScene(board.shapes)
        quiet.settle()
        quiet.editor.selectedShapeIDs = [board.corolla]
        let none = try require(quiet.h.secondaryClick(at: CGPoint(x: 400, y: 30)))
        expect(none.outline.contains("Ignore Rule ▸"), "\(none.outline)")
        expect(!none.outline.contains("Walk Flagged"), "nothing flags it: \(none.outline)")
    },
    test("in a list without Validation's walk neither Walk Flagged is offered, and a rule's count selects the shapes it counts as it did") {
        let board = Listings()
        let beetle = card("1972 Beetle", of: [board.listing], id: ShapeID(), at: CGPoint(x: 600, y: 0))
        let scene = try RuleScene(board.shapes + [beetle], decisions: answering(flagsFirst), walk: false)
        scene.settle()
        expect(scene.editor.issueWalk == nil)
        scene.editor.selectedShapeIDs = [board.listing]
        let type = try require(scene.h.secondaryClick(at: CGPoint(x: 100, y: 130)))
        expect(type.outline.contains("Select Flagged ▸"), "\(type.outline)")
        expect(!type.outline.contains("Walk Flagged"), "\(type.outline)")
        scene.editor.selectedShapeIDs = [beetle.id]
        let shape = try require(scene.h.secondaryClick(at: CGPoint(x: 700, y: 30)))
        expect(shape.outline.contains("Ignore Rule ▸"), "\(shape.outline)")
        expect(!shape.outline.contains("Walk Flagged"), "\(shape.outline)")
        // The count's click goes to the shapes themselves.
        let panel = RulesPanelWindow(scene)
        defer { panel.window.close() }
        try panel.show(board.listing, on: .of(RulesTab.self))
        panel.window.spin { panel.boxes.count == 3 && !panel.buttons.isEmpty }
        try require(panel.buttons.first).performClick(nil)
        scene.scheduler.advance(by: .zero)
        expectEqual(Set(scene.editor.selectedShapeIDs), [board.corolla, beetle.id], "the count selects the shapes")
    },
    test("a checked shape's menu has Ignore Rule, a check by what it ignores: a pick ignores it in one step, and again stops") {
        let board = Listings()
        let scene = try RuleScene(board.shapes, decisions: answering(flagsFirst))
        scene.settle()
        scene.editor.selectedShapeIDs = [board.corolla]
        var menu = try require(scene.h.secondaryClick(at: CGPoint(x: 400, y: 30)))
        expect(menu.outline.contains("Ignore Rule ▸"), "\(menu.outline)")
        expect(menu.outline.contains("  \(cut(Listings.agrees))"), "\(menu.outline)")
        try menu.choose("Ignore Rule", cut(Listings.agrees))
        expectEqual(scene.editor.undoHistory.undoName, "Ignore Rule")
        menu = try require(scene.h.secondaryClick(at: CGPoint(x: 400, y: 30)))
        expect(menu.outline.contains("  ✓ \(cut(Listings.agrees))"), "\(menu.outline)")
        try menu.choose("Ignore Rule", cut(Listings.agrees))
        expectEqual(scene.editor.undoHistory.undoName, "Stop Ignoring Rule")
        expect(scene.editor.document[board.corolla]?[IgnoredRulesProperty.self] == nil)
    },
    test("Retry Rules is in the menu while a check failed for a reason trying again may mend, and asks again") {
        let board = Listings()
        let decisions = ScriptedDecisionModel()
        decisions.fallback = { _ in .failure(DecisionModelError(.network("offline"), provider: "TypeSafe")) }
        let scene = try RuleScene(board.shapes, decisions: decisions)
        scene.settle()
        expect(scene.checks.failure != nil)
        scene.editor.selectedShapeIDs = [board.corolla]
        let menu = try require(scene.h.secondaryClick(at: CGPoint(x: 400, y: 30)))
        expect(menu.outline.contains("Retry Rules"), "\(menu.outline)")
        decisions.fallback = { request in
            .success(DecisionAnswers(model: "scripted", yes: Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, 0.1) })))
        }
        let asked = decisions.requests.count
        try menu.choose("Retry Rules")
        scene.settle()
        expectEqual(decisions.requests.count, asked + 1)
        expect(scene.checks.failure == nil)
        let after = try require(scene.h.secondaryClick(at: CGPoint(x: 400, y: 30)))
        expect(!after.outline.contains("Retry Rules"), "nothing failed: \(after.outline)")
    },
])

// MARK: In a window

/// The panel alone in an unshown window, over a scene's editor: SwiftUI lands as the run loop runs, the editor's own
/// waits as the scene's scheduler is advanced.
@MainActor
final class RulesPanelWindow {
    let scene: RuleScene
    let window: NSWindow
    let hosting: NSView

    init(_ scene: RuleScene) {
        self.scene = scene
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: DetailPanelView(editor: scene.editor, onExit: {}).environment(\.locale, Locale(identifier: "en_US")))
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        window.contentView = hosting
        window.settle()
    }

    /// Shows a shape's panel on a tab.
    func show(_ id: ShapeID, on tab: DetailTabID) throws {
        let record = try require(scene.editor.document[id])
        scene.editor.detailPanel?.choose(tab, for: record.kind)
        scene.editor.selectedShapeIDs = [id]
        window.settle()
        scene.scheduler.advance(by: .milliseconds(100))
        window.settle()
    }

    /// The panel's text views below its header, in reading order.
    var boxes: [NSTextView] { hosting.descendants(NSTextView.self).filter { !$0.isFieldEditor && $0.convert($0.bounds, to: hosting).maxY > 44 } }
    /// The panel's buttons below its header, in reading order: SwiftUI draws their titles itself, so a test tells them
    /// apart by place.
    var buttons: [NSButton] {
        var placed: [(button: NSButton, frame: CGRect)] = []
        for button in hosting.descendants(NSButton.self) {
            let frame = button.convert(button.bounds, to: nil)
            // Below the header: its top 44 points, in the window's coordinates, whose y goes up.
            if frame.maxY < window.contentLayoutRect.maxY - 44 { placed.append((button, frame)) }
        }
        placed.sort { a, b in abs(a.frame.maxY - b.frame.maxY) > 4 ? a.frame.maxY > b.frame.maxY : a.frame.minX < b.frame.minX }
        return placed.map(\.button)
    }

    /// Types `text` in a box and presses Return.
    func type(_ text: String, in box: NSTextView) {
        window.makeFirstResponder(box)
        window.settle()
        window.type(text)
        window.pressReturn()
        window.settle()
    }
}

/// The sRGB components and opacity `appearance` resolves `color` to.
@MainActor private func components(_ color: NSColor, in name: NSAppearance.Name) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
    var found: NSColor?
    try require(NSAppearance(named: name)).performAsCurrentDrawingAppearance { found = color.usingColorSpace(.sRGB) }
    let color = try require(found)
    return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
}

@MainActor let ruleWindowTests = Suite("Rules in the panel, in a window", [
    test("a type's Rules tab: a box a rule, then add rule; a rule typed and Return adds it in one step, one edited changes it, one emptied goes") {
        let board = Listings()
        let scene = try RuleScene(board.shapes)
        let panel = RulesPanelWindow(scene)
        defer { panel.window.close() }
        try panel.show(board.listing, on: .of(RulesTab.self))
        panel.window.spin { panel.boxes.count == 3 }
        expectEqual(panel.boxes.map(\.string), [Listings.agrees, Listings.noDamage, ""])
        panel.type("The price is in dollars.", in: panel.boxes[2])
        expectEqual(scene.editor.undoHistory.undoName, "Change Rules")
        expectEqual(RuleBook.rules(of: board.listing, in: scene.editor).map(\.says), [Listings.agrees, Listings.noDamage, "The price is in dollars."])
        panel.window.spin { panel.boxes.count == 4 }
        let box = panel.boxes[1]
        panel.window.makeFirstResponder(box)
        box.selectAll(nil)
        panel.window.type("The description mentions no rust.")
        panel.window.pressReturn()
        panel.window.settle()
        expectEqual(RuleBook.rules(of: board.listing, in: scene.editor).map(\.says), [Listings.agrees, "The description mentions no rust.", "The price is in dollars."])
        panel.window.makeFirstResponder(panel.boxes[0])
        panel.boxes[0].selectAll(nil)
        panel.window.press(Chord(Key.delete))
        panel.window.pressReturn()
        panel.window.settle()
        expectEqual(RuleBook.rules(of: board.listing, in: scene.editor).map(\.says), ["The description mentions no rust.", "The price is in dollars."])
    },
    test("a rule's count says how many shapes it flags, and its click, or Return, begins the rule's walk at its first stop; Select Flagged still selects them") {
        let board = Listings()
        let beetle = card("1972 Beetle", of: [board.listing], id: ShapeID(), at: CGPoint(x: 600, y: 0))
        let scene = try RuleScene(board.shapes + [beetle], decisions: answering(flagsFirst))
        scene.settle()
        let panel = RulesPanelWindow(scene)
        defer { panel.window.close() }
        let walk = try require(scene.editor.issueWalk)
        try panel.show(board.listing, on: .of(RulesTab.self))
        panel.window.spin { panel.boxes.count == 3 && !panel.buttons.isEmpty }
        // The one button of Listing's tab: Car, which it builds on, has no rules to list.
        var count = try require(panel.buttons.first)
        expect(!walk.isRunning)
        count.performClick(nil)
        scene.scheduler.advance(by: .zero)
        expect(walk.isRunning, "the click begins the walk")
        expectEqual(walk.scope?.label(scene.editor)?.title, "Rule 1")
        expectEqual(walk.currentRow?.shape, board.corolla, "at the first flagged shape in board order")
        expectEqual(walk.number, 1)
        expectEqual(walk.total, 2)
        expectEqual(scene.editor.selectedShapeIDs, [board.corolla], "the count no longer selects the shapes it counts")
        // Return, with the count focused, begins it too (`onKeyPress`: a button answers Space, and Return only as the default). SwiftUI
        // focus, which the key press needs, reaches the count only with Keyboard navigation on; with it off the key is unverified
        // here (the menu's Walk Flagged ▸ is the way with it off).
        walk.end()
        try panel.show(board.listing, on: .of(RulesTab.self))
        panel.window.spin { panel.boxes.count == 3 && !panel.buttons.isEmpty }
        count = try require(panel.buttons.first)
        if NSApplication.shared.isFullKeyboardAccessEnabled {
            expect(panel.window.makeFirstResponder(count), "the count takes the keyboard")
            panel.window.pressReturn()
            panel.window.settle()
            scene.scheduler.advance(by: .zero)
            expect(walk.isRunning, "Return begins it too")
            expectEqual(walk.currentRow?.shape, board.corolla)
            expectEqual(walk.number, 1)
        } else {
            FileHandle.standardError.write(Data("skipped: Return on a rule's count (Keyboard navigation is off; Walk Flagged ▸ is the way)\n".utf8))
        }
        // Select Flagged ▸ is the menu's way to select them all.
        walk.end()
        scene.editor.selectedShapeIDs = [board.listing]
        let menu = try require(scene.h.secondaryClick(at: CGPoint(x: 100, y: 130)))
        try menu.choose("Select Flagged", "\(cut(Listings.agrees)) (2)")
        expectEqual(Set(scene.editor.selectedShapeIDs), [board.corolla, beetle.id])
        expect(!walk.isRunning, "selecting begins no walk")
    },
    test("the rules a type inherits come after its own, dimmed, from their type; a click goes there") {
        let board = Listings()
        let vintage = typeCard("Vintage", rules: ["Wear is expected on a vintage car."], builds: [board.listing], at: CGPoint(x: 0, y: 300))
        let scene = try RuleScene(board.shapes + [vintage])
        let panel = RulesPanelWindow(scene)
        defer { panel.window.close() }
        try panel.show(vintage.id, on: .of(RulesTab.self))
        panel.window.spin { panel.boxes.count == 2 }
        expectEqual(panel.boxes.map(\.string), ["Wear is expected on a vintage car.", ""], "its own and add rule: the inherited aren't boxes")
        // Its buttons: the two rules it has from Listing, no count (its own rule flags nothing).
        expectEqual(panel.buttons.count, 2)
        try require(panel.buttons.first).performClick(nil)
        scene.scheduler.advance(by: .zero)
        expectEqual(scene.editor.selectedShapeIDs, [board.listing])
    },
    test("the Rules tab by keys: Tab walks each rule's box and add rule in reading order, Shift-Tab back") {
        let board = Listings()
        let scene = try RuleScene(board.shapes)
        let panel = RulesPanelWindow(scene)
        defer { panel.window.close() }
        try panel.show(board.listing, on: .of(RulesTab.self))
        panel.window.spin { panel.boxes.count == 3 }
        let walk = KeyWalk(panel.window, editor: scene.editor, menu: nil, readers: [], settle: .both(scene.scheduler))
        walk.standardControls = ["window/flags 1", "window/flags 2"]
        panel.window.makeFirstResponder(panel.boxes[0])
        panel.window.settle()
        scene.scheduler.advance(by: .milliseconds(100))
        expectEqual(walk.focus.id, "window/Rule 1")
        walk.expectCycle(inOrder: ["window/Rule 1", "window/Rule 2", "window/add rule"], wraps: .closed)
        walk.expectShows([walk.focus])
    },
    test("the Issues tab: the line, then the Rules section with each rule's state, and Shown, one stop of Tab that ↑ ↓ walk and light") {
        let board = Listings()
        let scene = try RuleScene(board.shapes, decisions: answering(flagsFirst))
        scene.settle()
        let panel = RulesPanelWindow(scene)
        defer { panel.window.close() }
        try panel.show(board.corolla, on: .of(IssuesTab.self))
        panel.window.spin { !panel.hosting.descendants(NSTableView.self).isEmpty }
        let table = try require(panel.hosting.descendants(NSTableView.self).first)
        let walk = KeyWalk(panel.window, editor: scene.editor, menu: nil, readers: [], settle: .both(scene.scheduler))
        panel.window.makeFirstResponder(table)
        panel.window.settle()
        expectEqual(scene.editor.outlines.tinted.flatMap(\.shapes), [board.listing, board.car], "on its first head: its types, lit")
        walk.press(.down)
        expectEqual(scene.editor.outlines.tinted.flatMap(\.shapes), [board.listing])
        walk.press(.return)
        scene.scheduler.advance(by: .zero)
        expectEqual(scene.editor.selectedShapeIDs, [board.listing], "Return goes to the shape")
        try panel.show(board.corolla, on: .of(IssuesTab.self))
        panel.window.spin { panel.buttons.count >= 2 }
        // The line's buttons come first: Ignore, then Show Rule.
        panel.buttons[0].performClick(nil)
        expectEqual(scene.editor.undoHistory.undoName, "Ignore Rule")
    },
    test("a chip's tint, found or asked about, follows the appearance its box is drawn in (a system color faded once is fixed to one)") {
        for (query, opacity) in [(ChippedListings.query, CGFloat(0.2)), (nil, 0.15)] {
            let board = ChippedListings()
            let scene = try RuleScene(board.shapes(query: query))
            let panel = RulesPanelWindow(scene)
            defer { panel.window.close() }
            try panel.show(board.listing, on: .of(RulesTab.self))
            panel.window.spin { (panel.boxes.first as? EditingTextView)?.highlights.isEmpty == false }
            let fill = try require((panel.boxes.first as? EditingTextView)?.highlights.first?.fill, "the chip, drawn")
            let light = try components(fill, in: .aqua), dark = try components(fill, in: .darkAqua)
            let said = query == nil ? "asked about" : "found"
            expect(light.red + light.green + light.blue < dark.red + dark.green + dark.blue, "darker drawn in the light than in the dark, \(said)")
            expectClose(light.alpha, opacity)
            expectClose(dark.alpha, opacity)
        }
    },
    test("a rule's chips by keys: Tab walks the sentence, then the chip, selected and said, then its line's query; Shift-Tab back onto the chip") {
        let board = ChippedListings()
        let scene = try RuleScene(board.shapes())
        let panel = RulesPanelWindow(scene)
        defer { panel.window.close() }
        try panel.show(board.listing, on: .of(RulesTab.self))
        panel.window.spin { panel.boxes.count == 3 }
        let box = try require(panel.boxes.first as? EditingTextView)
        expectEqual(box.highlights.map(\.range), [NSRange(location: 14, length: 18)], "the chip, drawn")
        expectEqual(box.highlights.first?.symbol, "magnifyingglass")
        expectEqual(box.string, ChippedListings.unlike, "the sentence as written")
        let walk = KeyWalk(panel.window, editor: scene.editor, menu: nil, readers: [], settle: .both(scene.scheduler))
        panel.window.makeFirstResponder(box)
        box.setSelectedRange(NSRange(location: 0, length: 0))
        panel.window.settle()
        walk.press(.tab)
        expect(panel.window.firstResponder === box, "inside the box still")
        expectEqual(box.selectedRange(), NSRange(location: 14, length: 18), "the chip selected")
        walk.press(.tab)
        expect(panel.window.firstResponder === panel.boxes[1], "on to the chip's query, under it")
        walk.press(.backTab)
        expect(panel.window.firstResponder === box, "back")
        expectEqual(box.selectedRange(), NSRange(location: 14, length: 18), "onto the last chip")
        walk.press(.backTab)
        expectEqual(box.selectedRange(), NSRange(location: 14, length: 0), "then the sentence, at the chip's start")
        expect(panel.window.firstResponder === box)
        box.setSelectedRange(NSRange(location: 3, length: 0))
        walk.press(.tab)
        expectEqual(box.selectedRange(), NSRange(location: 14, length: 18), "from anywhere in the sentence, the first chip")
        walk.press(.backTab)
        expectEqual(box.selectedRange(), NSRange(location: 3, length: 0), "and back to exactly where the caret was")
        walk.press(.tab)
        walk.press(.tab)
        let query = try require(panel.boxes[1] as? EditingTextView)
        expect(panel.window.firstResponder === query, "the chip's query, in its box")
        let chip = RuleChip(phrase: ChippedListings.others, query: ChippedListings.query)
        let chips = try require(scene.editor.ruleChips)
        expectEqual(chips.preview(of: chip, type: board.listing).sample, "2021 Toyota Corolla LE")
        walk.press(.tab)
        walk.press(.right)
        expectEqual(chips.preview(of: chip, type: board.listing).sample, "2019 Toyota Camry SE", "the sample, stepped by keys")
        walk.press(.left)
        expectEqual(chips.preview(of: chip, type: board.listing).sample, "2021 Toyota Corolla LE", "and back")
    },
    test("@ in a rule's box lists shapes and then the words; the words taken are a chip, asked of the model, its line saying the draft's query") {
        let board = ChippedListings()
        let language = ScriptedLanguageModel(answers: [#"card:is-a("Listing"):not(:scope)"#])
        let scene = try RuleScene(Array(board.shapes(query: nil).dropFirst()) + [typeCard("Listing", rules: ["Priced unlike"], id: board.listing)], language: language)
        let panel = RulesPanelWindow(scene)
        defer { panel.window.close() }
        try panel.show(board.listing, on: .of(RulesTab.self))
        panel.window.spin { panel.boxes.count == 2 }
        let box = try require(panel.boxes.first as? MentionTextView<AnyMentionable>)
        panel.window.makeFirstResponder(box)
        box.setSelectedRange(NSRange(location: box.string.count, length: 0))
        panel.window.type(" @the rest")
        expectEqual(box.picker?.rows.last, .words("the rest"))
        panel.window.pressReturn()
        expectEqual(box.string, "Priced unlike the rest", "the words, in the @'s place")
        expectEqual(box.highlights.map(\.range), [NSRange(location: 14, length: 8)])
        panel.window.spin { scene.editor.ruleChips?.preview(of: RuleChip(phrase: "the rest", query: nil), type: board.listing).query != nil }
        expectEqual(language.requests.count, 1)
        panel.window.type(".")
        panel.window.pressReturn()
        panel.window.settle()
        expectEqual(RuleBook.rules(of: board.listing, in: scene.editor).first,
                    Rule(says: "Priced unlike the rest.", find: [RuleChip(phrase: "the rest", query: #"card:is-a("Listing"):not(:scope)"#)]))
    },
])
