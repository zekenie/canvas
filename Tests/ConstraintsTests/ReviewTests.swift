import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import Constraints
import CoreGraphics
import DetailPanel
import LanguageModels
import Palette
import QueryTranslation
import Selection
import SlashCommands
import TestKit
import Titles
import Validation

// What review of the faces found: the keyboard staying in a row a write changes, Escape letting go of words typed, words
// that survive a write to their row's reach while the model is out, a list without the faces plugin, a holder's lists from
// elsewhere, and the whole panel walked by keys.

private let penRect = CGRect(x: 100, y: 100, width: 400, height: 300)


@MainActor let reviewFixTests = Suite("Constraints: faces, review", [
    test("the keyboard stays in a row after a write to it: its reach changed, its words landed") {
        let model = ScriptedLanguageModel(answers: [#"tile[finish="glossy"]"#])
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect, [onlyTiles, noDiscs])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 5 }
        let first = panel.boxes[0]
        panel.window.makeFirstResponder(first)
        panel.window.settle()
        h.editor.constraintBoxes?.setReach(.descendants, of: onlyTiles, in: pen)
        panel.window.settle()
        h.scheduler.advance(by: .milliseconds(100))
        panel.window.settle()
        expect(panel.boxes[0] === first, "the row's views are kept")
        expect(panel.window.firstResponder === first, "and the keyboard is in them")
        first.selectAll(nil)
        panel.window.type("only glossy tiles")
        panel.window.pressReturn()
        panel.land(after: model, answers: 1)
        expectEqual(h.list(of: pen).first?.says, "only glossy tiles")
        expect(panel.boxes[0] === first, "kept when the words land")
        expect(panel.window.firstResponder is NSTextView, "the keyboard is still in the panel: \(String(describing: panel.window.firstResponder))")
    },
    test("Escape in a box lets go of the words typed (nothing is asked or added); with none it is the panel's") {
        let model = ScriptedLanguageModel(answers: ["tile"])
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect, [noDiscs])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 3 }
        let boxes = try require(h.editor.constraintBoxes)
        let adding = ConstraintBox(holder: pen, constraint: nil)
        panel.window.makeFirstResponder(panel.boxes[2])
        panel.window.settle()
        panel.window.type("only tiles")
        panel.window.settle()
        expect(boxes.hasDraft(adding))
        panel.window.pressEscape()
        panel.window.settle()
        expect(!boxes.hasDraft(adding), "the draft is let go")
        expectEqual(panel.boxes[2].string, "", "and the box is empty")
        h.scheduler.advance(by: .milliseconds(700))
        panel.land()
        expectEqual(h.list(of: pen), [noDiscs])
        expectEqual(model.requests.count, 0, "the model is never asked")
        // A row's words come back as they were.
        panel.window.makeFirstResponder(panel.boxes[0])
        panel.window.type("x")
        panel.window.settle()
        panel.window.pressEscape()
        panel.window.settle()
        expectEqual(panel.boxes[0].string, "no discs")
    },
    test("Escape while the model is asked drops the words: what comes lands nothing") {
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        model.queue("tile")
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect, [noDiscs])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 3 }
        panel.type("only tiles", in: panel.boxes[2])
        panel.land()
        let boxes = try require(h.editor.constraintBoxes)
        expectEqual(boxes.status(of: ConstraintBox(holder: pen, constraint: nil)), .interpreting)
        panel.window.makeFirstResponder(panel.boxes[2])
        panel.window.pressEscape()
        panel.window.settle()
        model.release()
        panel.land(after: model, answers: 1)
        expectEqual(h.list(of: pen), [noDiscs])
    },
    test("a row's words edited, then its reach changed while the model is out: the words land on the row as it is now") {
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        model.queue(#"tile[finish="glossy"]"#)
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect, [onlyTiles])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 3 }
        panel.window.makeFirstResponder(panel.boxes[0])
        panel.boxes[0].selectAll(nil)
        panel.window.type("only glossy tiles")
        panel.window.pressReturn()
        panel.land()
        panel.window.spin { model.waiting == 1 }
        let boxes = try require(h.editor.constraintBoxes)
        expectEqual(boxes.status(of: ConstraintBox(holder: pen, constraint: onlyTiles)), .interpreting)
        h.writer.setReach(.descendants, of: onlyTiles, in: .shape(pen))
        panel.land()
        expectEqual(boxes.status(of: ConstraintBox(holder: pen, constraint: Constraint(says: "only tiles", query: "tile", reach: .descendants))), .interpreting,
                    "the words are still being asked")
        model.release()
        panel.land(after: model, answers: 1)
        expectEqual(h.list(of: pen), [Constraint(says: "only glossy tiles", query: #"tile[finish="glossy"]"#, reach: .descendants)])
    },
    test("/unconstrain shakes only a frozen list the pick would have changed") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let pen = h.corral("Pen", penRect, [noDiscs]), empty = h.corral("Empty", CGRect(x: 600, y: 100, width: 150, height: 150))
        let holds = h.corral("Holds", CGRect(x: 600, y: 300, width: 150, height: 150), [noDiscs])
        h.editor.freeze([empty, holds])
        let commands = try require(h.editor.slashCommands)
        let command = try require(commands.command(named: "unconstrain", for: .selection([pen, empty, holds])))
        let choice = try require(command.choices().first { $0.title == "no discs" })
        expect(commands.run(command, choosing: choice))
        expectEqual(h.list(of: pen), [])
        expect(!log.refusals.contains { $0.contains(empty) }, "nothing on it to remove")
        expect(log.refusals.contains { $0.contains(holds) }, "it has the constraint")
    },
    test("without ConstraintFacesPlugin a holder has no section and no menu") {
        let plugins = constraintPlugins().filter { !($0 is ConstraintFacesPlugin) }
        let h = try EditorHarness(plugins: plugins)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let charter = h.add(Charter(CGRect(x: 100, y: 100, width: 100, height: 80), name: "Sprint"))
        let panel = try require(h.editor.detailPanel)
        let sections = try panel.layout(for: require(h.editor.document[charter])).sections(in: .of(RulesTab.self)).map(\.section)
        expectEqual(sections, [])
        h.editor.selectedShapeIDs = [charter]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 150, y: 140)))
        expect(!menu.outline.contains { $0.hasPrefix("Constraints") }, "\(menu.outline)")
    },
    test("an untitled container is named to the model as \"this frame\", mid-sentence") {
        let model = ScriptedLanguageModel(answers: ["tile"])
        let h = try constraintHarness(model: model)
        let plain = h.corral(nil, penRect, [noDiscs])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(plain)
        panel.window.spin { panel.boxes.count == 3 }
        panel.type("only tiles", in: panel.boxes[2])
        panel.land(after: model, answers: 1)
        expect(model.lastRequest?.system?.hasSuffix("which shapes this corral accepts.") == true, "\(model.lastRequest?.system ?? "")")
    },
    test("a holder's lists from elsewhere show dimmed and read-only before its own rows, the pill goes to their holder, and they follow it") {
        let h = try constraintHarness(Given(), [wardFixtures()])
        let charter = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint"))
        h.writer.add(noDiscs, to: .shape(charter))
        let ward = h.add(Ward(CGRect(x: 100, y: 100, width: 100, height: 80)))
        h.writer.add(onlyTiles, to: .shape(ward))
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(ward)
        panel.window.spin { panel.boxes.count >= 3 }
        expectEqual(panel.boxes.map(\.string), [":not(disc)", "only tiles", "tile", ""], "the list from elsewhere has its read-only query box, as a frame's does, then its own words, query and the add box")
        expectEqual(panel.boxes.first?.accessibilityLabel(), "Query of no discs", "a stop, named for its words")
        @MainActor func addY() -> CGFloat { panel.boxes[panel.boxes.count - 1].convert(panel.boxes[panel.boxes.count - 1].bounds, to: panel.hosting).minY }
        let before = addY()
        h.writer.add(onlyGlossy, to: .shape(charter))
        h.settle()
        for _ in 0..<5 {
            panel.window.settle()
            h.scheduler.advance(by: .milliseconds(100))
        }
        expect(addY() != before, "the source's new constraint adds a row above the add box")
        let pill = try require(panel.buttons.first { !($0 is NSPopUpButton) })
        pill.performClick(nil)
        h.scheduler.advance(by: .zero)
        expectEqual(h.editor.selectedShapeIDs, [charter], "the pill goes to the holder")
        // And the menu: Go to Sprint.
        h.editor.selectedShapeIDs = [ward]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 150, y: 140)))
        expect(menu.outline.contains("  Go to Sprint"), "\(menu.outline)")
    },
    test("Constraints ▸ offers Interpret Constraint for words with no query, and a breaker's Show Constraint rows are cut like the menu's") {
        let model = ScriptedLanguageModel(answers: ["tile"])
        let h = try constraintHarness(model: model)
        let long = "only things that are tiles and that someone has already looked at in the planning meeting last week"
        let pen = h.corral("Pen", penRect, [Constraint(says: "only tiles"), Constraint(says: long, query: "tile"), Constraint(says: long + " too", query: "tile")])
        h.editor.selectedShapeIDs = [pen]
        var menu = try require(h.secondaryClick(at: CGPoint(x: 150, y: 150)))
        expect(menu.outline.contains("    Interpret Constraint"), "\(menu.outline)")
        try menu.choose("Constraints", "only tiles", "Interpret Constraint")
        h.wait(0)
        let drawn = try require(h.editor.constraintBoxes)
        expect(drawn.hasDraft(ConstraintBox(holder: pen, constraint: Constraint(says: "only tiles"))), "asking")
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        h.editor.selectedShapeIDs = [d]
        menu = try require(h.secondaryClick(at: CGPoint(x: 225, y: 225)))
        let shows = menu.outline.filter { $0.contains("Pen: only things") }
        expect(!shows.isEmpty && shows.allSatisfy { $0.count < 90 }, "\(shows)")
    },
    test("a long constraint's words show in full in a row's box: it is two lines tall") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [Constraint(says: "only things that are tiles and that someone has already looked at in the planning meeting", query: "tile")])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 3 }
        expect(panel.boxes[0].enclosingScrollView.map { $0.frame.height >= 30 } == true, "\(String(describing: panel.boxes[0].enclosingScrollView?.frame))")
    },
    test("a container's own rows are headed Own against lists from elsewhere, and Accepts alone") {
        expectEqual(ConstraintsStyle.ownHeading(hasSources: false), "Accepts")
        expectEqual(ConstraintsStyle.ownHeading(hasSources: true), "Own")
    },
    test("by keys, every stop of one panel: a list from elsewhere, own rows (one with no query), the add box and Not accepted; shown, named, and back by Shift-Tab") {
        let given = Given()
        let h = try constraintHarness(given)
        let sprint = h.add(Charter(CGRect(x: 800, y: 50, width: 100, height: 80), name: "Sprint"))
        let backlog = h.corral("Backlog", CGRect(x: 40, y: 50, width: 300, height: 200), [Constraint(says: "no discs", query: ":not(disc)"), Constraint(says: "only urgent")])
        h.disc(at: CGPoint(x: 200, y: 120), in: backlog)
        given.lists[backlog] = [ConstraintSource(holder: sprint, swatch: Swatch(RGB(hex: 0x4465E9)),
                                                 constraints: [Constraint(says: "only tasks and bugs", query: "tile, disc")])]
        h.index.inheritedConstraintsDidChange(of: [backlog])
        h.settle()
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(backlog)
        panel.window.spin { panel.boxes.count >= 5 }
        let walk = KeyWalk(panel.window, editor: h.editor, menu: nil, readers: [], settle: .both(h.scheduler))
        walk.standardControls = ["window/Sprint", "window/Remove no discs", "window/Reach of no discs", "window/Remove only urgent", "window/Reach of only urgent",
                                 "window/Interpret"]
        panel.window.makeFirstResponder(panel.boxes[0])
        panel.window.settle()
        h.scheduler.advance(by: .milliseconds(100))
        let cycle = walk.expectCycle(inOrder: ["window/Query of only tasks and bugs", "window/Constraint 1", "window/Query of no discs", "window/Constraint 2",
                                               "window/add constraint"], wraps: .closed)
        walk.expectShows(cycle.stops)
    },
])

// A second holder kind, a type's stand-in that builds on every named charter (as a type builds on its supertypes): its
// `InheritedConstraints` reads the charters' lists from the file, as Types reads a supertype's.
struct Ward: BoxShapeProps {
    static let kind: ShapeKind = "ward"
    static let properties = Properties<Ward> {
        Property("frame", \.frame).required()
        Property("list", \.list)
    }
    var frame: CGRect
    var list = "[]"
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

struct WardDefinition {}
extension WardDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Ward>, in context: RenderContext) {}
}

enum Warded {}
extension Warded: ShapeProperty {
    static let key: PropertyKey = "warded"
    static var defaultValue: Bool? { nil }
}

@MainActor func wardFixtures() -> Contributor {
    Contributor(id: "ward-fixtures") { r in
        r.shape(WardDefinition())
        r.declare(Warded.self)
        r.optIn(Ward.self, to: Warded.self)
        r.forShapes(holding: Warded.self) { wards in
            wards.constraintHolder(read: { record, _ in
                guard let ward = record.typed(as: Ward.self), let data = ward.props.list.data(using: .utf8) else { return nil }
                return (try? JSONDecoder().decode(ConstraintList.self, from: data))?.constraints ?? []
            }, write: { list, id, transaction in
                guard let data = try? JSONEncoder().encode(ConstraintList(list)) else { return false }
                transaction.update(inFile: id, as: Ward.self) { $0.props.list = String(decoding: data, as: UTF8.self) }
                return true
            }, name: { _, _ in "each ward" })
            wards.inheritedConstraints { _, editor in
                editor.document.shapes.filter { $0.kind == Charter.kind }.compactMap { record -> ConstraintSource? in
                    guard let list = editor.constraintWriter?.constraints(of: .shape(record.id)), !list.isEmpty else { return nil }
                    return ConstraintSource(holder: record.id, swatch: Swatch(RGB(hex: 0x4465E9)), constraints: list)
                }
            }
        }
    }
}


@MainActor func axLabels(_ root: Any, depth: Int = 0) -> [String] {
    guard depth < 40, let el = root as? NSAccessibilityProtocol else { return [] }
    var found: [String] = []
    if let label = el.accessibilityLabel(), !label.isEmpty { found.append(label) }
    for child in el.accessibilityChildren() ?? [] { found += axLabels(child, depth: depth + 1) }
    return found
}
