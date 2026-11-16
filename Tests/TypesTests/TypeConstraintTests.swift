@_spi(Host) import Canvas
import AppKit
import CanvasTesting
import Colors
import Constraints
import CoreGraphics
import DetailPanel
import Foundation
import Observation
import Palette
import Queries
import QueryTranslation
import Selection
import SlashCommands
import SwiftUI
import TestKit
import Titles
import Types
import Validation

// A type's constraints (`TypeConstraintsPlugin`): `$constraints` held aside in its schema as `$rules` is, a type note a
// holder Constraints' writer writes through, the frames of a type having the lists of its chain, most general first, and
// Constraints told when they change with no commit to the frame.

@MainActor private final class Heard {
    var changes: [TypeChange] = []
    var held: [TypeHeldChange] = []
}

@MainActor let typeConstraintBookTests = Suite("A type's constraints in its schema", [
    test("$constraints is held aside as $rules is: the model is never sent it, a schema written whole keeps it, a change to it alone is no change to the fields") {
        let h = try typeConstraintHarness()
        let registry = h.editor.registry
        expect(registry.heldDirectives.isHeld("$constraints"), "a directive of the registry's")
        let task = h.type("Task", [onlyTasks])
        let held = try require(h.editor.schema(task))
        expect(held.contains("$constraints"), held)
        let stripped = registry.heldDirectives.stripped(held)
        expect(!stripped.contains("$constraints") && stripped.contains("\"properties\""), "never sent to the model: \(stripped)")
        let written = registry.heldDirectives.carried(from: held, into: #"{"properties": {"a": {"type": "string"}}}"#)
        expectEqual(TypeConstraintBook.constraints(inSchema: written).map(unbound), [onlyTasks], "kept by a schema written whole")
        let said = #"{"properties": {"$constraints": {"const": []}, "a": {}}}"#
        expectEqual(registry.heldDirectives.carried(from: held, into: said), said, "unless it says it")
        expect(registry.heldDirectives.sameButHeld(held, stripped), "the same type's fields")
        // A change to it alone moves no revision and tells no type changed; it is a held change.
        let types = h.types, heard = Heard()
        types.onChange { heard.changes.append($0) }
        types.onHeldChange { heard.held.append($0) }
        let revision = types.revision(of: task)
        h.writer.add(noBugs, to: .shape(task))
        expectEqual(types.revision(of: task), revision)
        expect(heard.changes.allSatisfy { $0.types.isEmpty }, "no type changed")
        expectEqual(heard.held.map(\.held), [[task]])
        h.editor.transact("Change JSON") { $0.update(task) { $0[TypeSchemaProperty.self] = SchemaText(#"{"properties": {"a": {}}}"#) } }
        expect(types.revision(of: task) != revision, "a field is a change")
    },
    test("read as a list is anywhere, written in a person's spacing, the rest of the text as typed; no JSON, no member or no list is none") {
        let text = """
        {
          "title": "Task",
          "properties": {
            "name": {"type": "string"}
          }
        }
        """
        expectEqual(TypeConstraintBook.constraints(inSchema: text), [])
        expectEqual(TypeConstraintBook.constraints(inSchema: "not json $constraints"), [])
        expectEqual(TypeConstraintBook.constraints(inSchema: #"{"properties": {"$constraints": {"const": "only"}}}"#), [], "not a list")
        let list = [onlyTasks, Constraint(says: "no bugs, ever", query: ":not(:is-a(\"Bug\"))", reach: .descendants), Constraint(says: "later")]
        let written = try require(TypeConstraintBook.text(text, setting: list))
        expectEqual(TypeConstraintBook.constraints(inSchema: written), list, "round trip: words, query (none for words not yet interpreted) and reach")
        expect(written.contains("\"name\": {\"type\": \"string\"}"), "the rest as typed: \(written)")
        expect(written.contains(#"{"says": "only tasks", "query": ":is-a(\"Task\")", "reach": "children"}"#), written)
        expectEqual(TypeConstraintBook.text(written, setting: []).map { TypeConstraintBook.constraints(inSchema: $0) }, [], "none takes the member away")
        expect(try require(TypeConstraintBook.text(written, setting: [])).contains("$constraints") == false)
        expectEqual(TypeConstraintBook.text("{", setting: list), nil, "no JSON object")
        let lenient = #"{"properties": {"$constraints": {"const": [{"says": "ok"}, 3, {"query": "x"}, {"says": "ok"}, {"says": "far", "reach": "descendants"}]}}}"#
        expectEqual(TypeConstraintBook.constraints(inSchema: lenient), [Constraint(says: "ok"), Constraint(says: "far", reach: .descendants)],
                    "a member that isn't a constraint, has no words or repeats one is passed over, never the list")
    },
    test("a type note is a holder: Constraints' writer reads and writes its list in one step, its panel section's heading is its noun's") {
        let h = try typeConstraintHarness()
        let sprint = h.type("Sprint"), pr = h.type("PR"), untitled = h.editor.addType(TypeSchemaProperty.starter)
        let plain = h.note("Plain", at: CGPoint(x: 40, y: 400))
        expectEqual(h.writer.constraints(of: .shape(sprint)), [])
        expectEqual(h.writer.constraints(of: .shape(plain)), nil, "a note that isn't a type holds none")
        expectEqual(h.editor.constraintHeading(of: sprint), "Inside each sprint")
        expectEqual(h.editor.constraintHeading(of: pr), "Inside each PR", "an acronym stays")
        expectEqual(h.editor.constraintHeading(of: untitled), nil, "no name, no heading")
        expectEqual(h.editor.constraintHeading(of: plain), nil)
        let before = h.editor.undoHistory.undoName
        let schemaBefore = h.editor.schema(sprint)
        expect(h.writer.add(onlyTasks, to: .shape(sprint)))
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint", "one step, named for what it does")
        expectEqual(h.writer.constraints(of: .shape(sprint)), [onlyTasks])
        expectEqual(TypeConstraintBook.constraints(inSchema: try require(h.editor.schema(sprint))), [onlyTasks], "in its schema")
        expect(!h.writer.add(onlyTasks, to: .shape(sprint)), "once")
        expect(h.writer.add(noBugs, to: .shape(sprint)))
        expect(h.writer.setReach(.descendants, of: noBugs, in: .shape(sprint)))
        expectEqual(h.writer.constraints(of: .shape(sprint)), [onlyTasks, Constraint(says: noBugs.says, query: noBugs.query, reach: .descendants)])
        expect(h.writer.remove(onlyTasks, from: .shape(sprint)))
        expect(h.writer.removeAll(from: .shape(sprint)))
        expectEqual(h.writer.constraints(of: .shape(sprint)), [])
        expectEqual(h.editor.schema(sprint), schemaBefore, "the member goes, the text comes back as it was")
        h.editor.undo()
        expectEqual(h.writer.constraints(of: .shape(sprint))?.map(\.says), [noBugs.says], "the last step undone")
        for _ in 0..<4 { h.editor.undo() }
        expectEqual(h.editor.undoHistory.undoName, before)
        expectEqual(h.writer.constraints(of: .shape(sprint)), [])
        // A schema that isn't JSON can't be written.
        h.editor.transact("Change JSON") { $0.update(sprint) { $0[TypeSchemaProperty.self] = SchemaText("{ not yet") } }
        expect(!h.writer.add(onlyTasks, to: .shape(sprint)), "nothing to write into")
        expectEqual(h.writer.refusal(of: sprint), "Schema isn't JSON yet.", "and the type says why, naming no type")
        expectEqual(h.editor.announcements.last, "Schema isn't JSON yet.", "heard as well")
        h.editor.transact("Change JSON") { $0.update(sprint) { $0[TypeSchemaProperty.self] = SchemaText(#"{"properties": 3}"#) } }
        expectEqual(h.writer.refusal(of: sprint), "Schema takes no list.", "JSON with no place for properties takes none either, and is JSON")
        h.editor.transact("Change JSON") { $0.update(sprint) { $0[TypeSchemaProperty.self] = SchemaText("[1]") } }
        expectEqual(h.writer.refusal(of: sprint), "Schema takes no list.", "a root that isn't an object likewise")
        // Each reason fits the bar's label: a failure's words are cut at that width.
        for reason in TypesStyle.schemaReasons {
            let label = NSTextField(labelWithString: reason)
            label.font = SlashBarStyle.labelFont
            let width = ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width)
            expect(width <= SlashBarStyle.failureRoom, "\(reason) is \(width) wide, the bar gives \(SlashBarStyle.failureRoom)")
        }
        h.editor.transact("Change JSON") { $0.update(sprint) { $0[TypeSchemaProperty.self] = SchemaText(#"{"title": "Sprint"}"#) } }
        expectEqual(h.writer.refusal(of: sprint), "Can't add a constraint to Sprint.", "where it can take one, none is refused: Constraints' own words stand")
    },
])

@MainActor let typeConstraintInheritanceTests = Suite("The constraints a frame has from its types", [
    test("a frame of a type has its types' lists along the chain, the most general first, each from its type with its name and color, then its own") {
        let h = try typeConstraintHarness()
        let work = h.type("Work", [onlyWork]), task = h.type("Task", on: [work], [onlyTasks, noBugs])
        let own = Constraint(says: "only small things", query: ":is-a(\"Task\")")
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task], [own])
        h.settle()
        expectEqual(h.given(to: backlog), [work, task], "the general first")
        let sources = h.index.sources(of: .shape(backlog))
        expectEqual(sources.map(\.holder), [work, task])
        expectEqual(sources.map(\.swatch), [h.types.look(of: work).swatch, h.types.look(of: task).swatch])
        expectEqual(sources.map { $0.constraints.map(unbound) }, [[onlyWork], [onlyTasks, noBugs]])
        expectEqual(h.index.constraints(of: .shape(backlog)).map(\.constraint.says), ["only work", "only tasks", "no bugs", "only small things"],
                    "each type's, then its own")
        expectEqual(h.index.constraints(of: .shape(backlog)).map(\.origin), [.inherited(work), .inherited(task), .inherited(task), .own])
        let bare = h.frame("Bare", CGRect(x: 500, y: 40, width: 200, height: 200))
        let other = h.type("Other")
        let plain = h.frame("Plain", CGRect(x: 500, y: 300, width: 200, height: 200), of: [other])
        expectEqual(h.given(to: bare), [], "a frame of no type has nothing from one")
        expectEqual(h.given(to: plain), [], "nor one of a type that holds none")
        expectEqual(h.index.constraints(of: .shape(bare)), [])
        // The type note itself is no place: what it holds is judged nowhere, but the lists of the types it builds on
        // are what its panel section shows (`sources(of:)`).
        expectEqual(try require(h.editor.typeConstraints).sources(of: task).map(\.holder), [work])
        expectEqual(try require(h.editor.typeConstraints).sources(of: work).map(\.holder), [])
    },
    test("a type's list written, with no commit to the frame, is heard: added, reached, reworded and taken away") {
        let h = try typeConstraintHarness()
        let task = h.type("Task")
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        h.settle()
        expectEqual(h.index.constraints(of: .shape(backlog)), [])
        let step = h.editor.undoHistory.undoName
        h.writer.add(onlyTasks, to: .shape(task))
        expectEqual(h.index.constraints(of: .shape(backlog)).map { unbound($0.constraint) }, [onlyTasks], "a commit to the type alone")
        h.writer.setReach(.descendants, of: onlyTasks, in: .shape(task))
        expectEqual(h.index.constraints(of: .shape(backlog)).map(\.constraint.reach), [.descendants])
        h.writer.replace(Constraint(says: onlyTasks.says, query: onlyTasks.query, reach: .descendants), with: Constraint(says: "just tasks", query: onlyTasks.query), in: .shape(task))
        expectEqual(h.index.constraints(of: .shape(backlog)).map(\.constraint.says), ["just tasks"])
        h.writer.removeAll(from: .shape(task))
        expectEqual(h.index.constraints(of: .shape(backlog)), [])
        h.editor.undo()
        expectEqual(h.index.constraints(of: .shape(backlog)).map(\.constraint.says), ["just tasks"], "undone")
        h.editor.undo()
        h.editor.undo()
        h.editor.undo()
        expectEqual(h.editor.undoHistory.undoName, step)
        expectEqual(h.index.constraints(of: .shape(backlog)), [])
    },
    test("a frame retyped, a type's own types changed, a type taken away and brought back: each is heard") {
        let h = try typeConstraintHarness()
        let work = h.type("Work", [onlyWork]), task = h.type("Task", on: [work], [onlyTasks]), bug = h.type("Bug", [noBugs])
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        h.settle()
        expectEqual(h.given(to: backlog), [work, task])
        // The frame's own `is`: a commit to it.
        h.retype(backlog, to: [bug])
        expectEqual(h.given(to: backlog), [bug])
        h.retype(backlog, to: [task])
        expectEqual(h.given(to: backlog), [work, task])
        // The type's own list: no commit to the frame.
        h.retype(task, to: [])
        expectEqual(h.given(to: backlog), [task], "Task no longer builds on Work")
        h.retype(task, to: [work, bug])
        expectEqual(Set(h.given(to: backlog)), [work, task, bug], "built on two")
        expectEqual(h.given(to: backlog).last, task, "Task, nearest, last")
        h.retype(task, to: [work])
        // A type that is no longer one (its schema taken away) gives nothing, but the chain goes on through it, as `:is-a` does:
        // the frame is Work through it.
        h.editor.transact("Not a type") { $0.update(task) { $0[TypeSchemaProperty.self] = nil } }
        expectEqual(h.given(to: backlog), [work], "what it was built on")
        h.editor.undo()
        expectEqual(h.given(to: backlog), [work, task], "brought back")
        // Deleted, with its instances left.
        h.editor.transact("Delete") { $0.delete([task]) }
        expectEqual(h.given(to: backlog), [])
        h.editor.undo()
        expectEqual(h.given(to: backlog), [work, task])
    },
    test("a type that holds no list, built on one that does, is heard changing what it is built on") {
        let h = try typeConstraintHarness()
        let work = h.type("Work", [onlyWork]), task = h.type("Task"), other = h.type("Other")
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        h.settle()
        expectEqual(h.given(to: backlog), [])
        h.retype(task, to: [work])
        expectEqual(h.given(to: backlog), [work], "through a type with no list")
        h.retype(task, to: [other])
        expectEqual(h.given(to: backlog), [])
    },
    test("a type recolored is heard: the color its pill has follows; a type renamed tells nothing, and the pill reads its name as it is") {
        let asked = ConstraintAsks()
        let h = try typeConstraintHarness([asked.plugin])
        let task = h.type("Task", [onlyTasks])
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        h.settle()
        @MainActor func swatch() -> Swatch? { h.index.sources(of: .shape(backlog)).first?.swatch }
        expectEqual(swatch(), h.types.look(of: task).swatch)
        // What the pill says is the holder's title as it is now, read observed: a view that shows it draws again on a rename.
        let told = Flag(), editor = h.editor
        let shown = withObservationTracking { editor.constraintSourceName(of: task) } onChange: { told.set() }
        expectEqual(shown, "Task")
        let count = asked.count, sources = h.index.sources(of: .shape(backlog))
        h.editor.transact("Rename") { $0.update(task) { $0[TitleProperty.self] = "Chore" } }
        h.settle()
        expect(told.isSet, "the name read is observed: a rename draws it again")
        expectEqual(h.editor.constraintSourceName(of: task), "Chore")
        expectEqual(asked.count, count, "no frame of the type asked again for a rename")
        expectEqual(h.index.sources(of: .shape(backlog)), sources, "what the frame is given is as it was")
        h.editor.transact("Untitle") { $0.update(task) { $0[TitleProperty.self] = nil } }
        h.settle()
        expectEqual(h.editor.constraintSourceName(of: task), "Untitled")
        expectEqual(asked.count, count)
        let other: ShapeColor = TypeColors.name(of: task) == .teal ? .pink : .teal
        h.editor.setColor(other, of: [task])
        expectEqual(swatch(), BuiltInColors.named(try require(other.name))?.swatch, "its pill's")
        expectEqual(swatch(), h.types.look(of: task).swatch)
        expect(asked.count > count, "a recolor is told")
        h.editor.setColor(nil, of: [task])
        expectEqual(swatch(), h.types.look(of: task).swatch, "its id's again")
    },
    test("a frame isn't asked again for a type that holds no list changing, nor for a change to a type's fields") {
        let asked = ConstraintAsks()
        let h = try typeConstraintHarness([asked.plugin])
        let task = h.type("Task"), other = h.type("Other")
        _ = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        h.settle()
        let count = asked.count
        h.editor.transact("Rename") { $0.update(other) { $0[TitleProperty.self] = "Another" } }
        h.editor.transact("Change JSON") { $0.update(task) { $0[TypeSchemaProperty.self] = SchemaText(#"{"properties": {"a": {}}}"#) } }
        h.editor.setColor(.teal, of: [task])
        h.settle()
        expectEqual(asked.count, count, "no type holds a list: nothing to tell")
        let work = h.type("Work")
        h.retype(task, to: [work])
        h.editor.transact("Delete") { $0.delete([other]) }
        h.editor.undo()
        h.settle()
        expectEqual(asked.count, count, "nor a type's types changed, or a type taken away and back")
        h.retype(task, to: [])
        h.writer.add(onlyTasks, to: .shape(task))
        h.settle()
        expect(asked.count > count, "a list written is told")
        let told = asked.count
        h.editor.transact("Change JSON") { $0.update(task) { $0[TypeSchemaProperty.self] = SchemaText(#"{"properties": {"b": {}, "$color": {"const": "teal"}, "$constraints": {"const": [{"says": "only tasks", "query": ":is-a(\"Task\")", "reach": "children", "names": {"Task": "\#(task)"}}]}}}"#) } }
        h.settle()
        expectEqual(asked.count, told, "a field changed, the list as it was")
    },
    test("a supertype's list written is heard by a frame of a type built on it, with no list of its own") {
        let h = try typeConstraintHarness()
        let work = h.type("Work"), task = h.type("Task", on: [work])
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        h.settle()
        h.writer.add(onlyWork, to: .shape(work))
        expectEqual(h.index.constraints(of: .shape(backlog)).map { unbound($0.constraint) }, [onlyWork], "reached through the chain")
        h.writer.setReach(.children, of: onlyWork, in: .shape(work))
        expectEqual(h.index.constraints(of: .shape(backlog)).map(\.constraint.reach), [.children])
        h.writer.removeAll(from: .shape(work))
        expectEqual(h.index.constraints(of: .shape(backlog)), [])
        h.editor.undo()
        expectEqual(h.index.constraints(of: .shape(backlog)).count, 1, "undone")
    },
    test("a type built on another is a holder, told by its supertype's list and by nothing else: no unrelated retitle, move or recolor of another shape reaches what observes its sources") {
        let h = try typeConstraintHarness()
        let work = h.type("Work", [onlyWork])
        let task = h.type("Task", on: [work])
        let bystander = h.frame("Bystander", CGRect(x: 40, y: 40, width: 200, height: 150))
        h.settle()
        let index = h.index
        @MainActor func tracking() -> Flag {
            let told = Flag()
            withObservationTracking { MainActor.assumeIsolated { _ = index.sources(of: .shape(task)) } } onChange: { told.set() }
            return told
        }
        expectEqual(index.sources(of: .shape(task)).map(\.holder), [work])
        var told = tracking()
        h.editor.transact("Retitle") { $0.update(bystander) { $0[TitleProperty.self] = "Renamed" } }
        h.editor.transact("Move") { $0.translate([bystander], by: CGPoint(x: 5, y: 5)) }
        expect(!told.isSet, "an unrelated retitle and move tell it nothing")
        h.writer.add(noBugs, to: .shape(work))
        h.settle()
        expect(told.isSet, "its supertype's list written tells it")
        expectEqual(index.sources(of: .shape(task)).first?.constraints.map(\.says), ["only work", "no bugs"])
        told = tracking()
        h.editor.setColor(.named("brand"), of: [work])
        expect(told.isSet, "its supertype recolored, which its pill shows")
        told = tracking()
        h.retype(task, to: [])
        expect(told.isSet, "no longer built on it")
        expectEqual(index.sources(of: .shape(task)).map(\.holder), [])
        told = tracking()
        h.retype(task, to: [work])
        expect(told.isSet, "built on it again")
        expectEqual(index.sources(of: .shape(task)).map(\.holder), [work])
    },
    test("a file put in place whose supertype's list differs: the subtype's section is told, and reads the list as the file has it") {
        let h = try typeConstraintHarness()
        let work = h.type("Work", [onlyWork])
        let task = h.type("Task", on: [work])
        h.settle()
        let index = h.index
        let saved = h.editor.file
        h.writer.add(noBugs, to: .shape(work))
        h.settle()
        expectEqual(index.sources(of: .shape(task)).first?.constraints.count, 2)
        let told = Flag()
        withObservationTracking { MainActor.assumeIsolated { _ = index.sources(of: .shape(task)) } } onChange: { told.set() }
        h.editor.replaceFile(with: saved)
        h.settle()
        h.wait(0)
        expectEqual(index.sources(of: .shape(task)).first?.constraints.map(\.says), ["only work"], "the file as it was")
        expect(told.isSet, "the section is told the list it shows changed")
    },
    test("a type that is no type now, in the chain, is told as it changes its own types") {
        let h = try typeConstraintHarness()
        let work = h.type("Work", [onlyWork])
        let task = h.type("Task", on: [work])
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        h.settle()
        h.editor.transact("Not a type") { $0.update(task) { $0[TypeSchemaProperty.self] = nil } }
        expectEqual(h.given(to: backlog), [work], "through a name that is no type, as :is-a")
        h.retype(task, to: [])
        h.settle()
        expectEqual(h.given(to: backlog), [], "Work's list no longer reaches the frame")
        h.retype(task, to: [work])
        h.settle()
        expectEqual(h.given(to: backlog), [work], "and again")
    },
    test("a schema that isn't JSON yet keeps the lists its frames had; fixing it tells nobody") {
        let asked = ConstraintAsks()
        let h = try typeConstraintHarness([asked.plugin])
        let task = h.type("Task", [onlyTasks])
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        let loose = h.note("Loose", at: CGPoint(x: 60, y: 60), in: backlog)
        h.settle()
        expectEqual(h.issues(of: loose), ["Backlog accepts only tasks."])
        let whole = try require(h.editor.schema(task))
        let count = asked.count
        h.editor.transact("Change JSON") { $0.update(task) { $0[TypeSchemaProperty.self] = SchemaText(String(whole.dropLast())) } }
        h.settle()
        expectEqual(h.given(to: backlog), [task], "the list it last had")
        expectEqual(h.issues(of: loose), ["Backlog accepts only tasks."])
        h.editor.transact("Change JSON") { $0.update(task) { $0[TypeSchemaProperty.self] = SchemaText(whole) } }
        h.settle()
        expectEqual(h.given(to: backlog), [task])
        expectEqual(asked.count, count, "no frame was asked again, going into the broken text or out of it")
    },
    test("a named file color a type is drawn in changing is heard: the label's swatch follows") {
        let h = try typeConstraintHarness()
        let task = h.type("Task", [onlyTasks])
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        h.settle()
        h.editor.setColor(.named("brand"), of: [task])
        @MainActor func swatch() -> Swatch? { h.index.sources(of: .shape(backlog)).first?.swatch }
        let held = swatch()
        expect(h.editor.defineColor(named: "Brand", value: RGB(hex: 0x123456)))
        expect(swatch() != held, "the file has the name now: the pill's color")
        expectEqual(swatch(), h.types.look(of: task).swatch)
        expect(h.editor.setColorValue(of: "brand", to: RGB(hex: 0xAA5500)))
        expectEqual(swatch(), h.types.look(of: task).swatch, "a value changed")
    },
    test("a file put in place is read afresh: what a type was last seen with is forgotten, so a later change is told") {
        let h = try typeConstraintHarness()
        let task = h.type("Task", [onlyTasks])
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        h.settle()
        let file = h.editor.file
        h.writer.removeAll(from: .shape(task))
        h.settle()
        expectEqual(h.given(to: backlog), [])
        h.editor.replaceFile(with: file)
        h.settle()
        expectEqual(h.given(to: backlog), [task], "its list is back")
        h.writer.removeAll(from: .shape(task))
        h.settle()
        expectEqual(h.given(to: backlog), [], "taken away again: told, not taken for what was last seen")
        expectEqual(h.index.constraints(of: .shape(backlog)), [])
    },
    test("a type deleted, or no longer a type, is no source in a chain; a deleted type's frames keep nothing from it") {
        let h = try typeConstraintHarness()
        let work = h.type("Work", [onlyWork])
        let task = h.type("Task", on: [work])
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        h.settle()
        expectEqual(h.given(to: backlog), [work])
        h.editor.transact("Not a type") { $0.update(work) { $0[TypeSchemaProperty.self] = nil } }
        h.settle()
        expectEqual(h.given(to: backlog), [], "a note that holds no schema holds no list, whatever its text once said")
        h.editor.undo()
        h.settle()
        expectEqual(h.given(to: backlog), [work])
        h.editor.transact("Delete") { $0.delete([work]) }
        h.settle()
        expectEqual(h.given(to: backlog), [])
        h.editor.undo()
        h.settle()
        expectEqual(h.given(to: backlog), [work], "brought back")
    },
    test("a big board: an unrelated commit, a rename of an unlisted type and a reworded constraint ask no whole file and judge few shapes") {
        let h = try typeConstraintHarness()
        let task = h.type("Task", [onlyTasks]), other = h.type("Other")
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        for x in 0..<60 { for y in 0..<50 { h.note("n", of: [], at: CGPoint(x: 600 + CGFloat(x) * 30, y: 40 + CGFloat(y) * 30)) } }
        let loose = h.note("Loose", at: CGPoint(x: 60, y: 60), in: backlog)
        h.settle()
        let queries = try require(h.editor.queries)
        let judged = h.index.shapesJudged, walked = h.index.placesWalked
        var whole = queries.standingWholeAsks
        h.editor.transact("Move") { $0.translate([loose], by: CGPoint(x: 5, y: 5)) }
        h.editor.transact("Elsewhere") { $0.insert(instanceRecord("x", of: [], title: "x", at: CGPoint(x: 100, y: 900))) }
        h.settle()
        expectEqual(queries.standingWholeAsks, whole, "a move and an insert outside ask no whole file")
        h.editor.transact("Rename") { $0.update(other) { $0[TitleProperty.self] = "Another" } }
        h.settle()
        // A name in a standing `:is-a` may mean another type now, which Types' queries ask once; Types' own hook asks no frame.
        expect(queries.standingWholeAsks - whole <= 1, "a type's rename: at most the one ask of the name-reading words")
        whole = queries.standingWholeAsks
        expect(h.index.placesWalked - walked <= 1, "no place's members walked again: \(h.index.placesWalked - walked)")
        expect(h.index.shapesJudged - judged <= 5, "a few shapes judged, not the board's 3,000: \(h.index.shapesJudged - judged)")
        // Reworded alone: the query standing is the same, so nothing is asked of the file.
        let words = TypeConstraintBook.constraints(inSchema: try require(h.editor.schema(task)))
        let reworded = Constraint(says: "just tasks", query: words[0].query, reach: words[0].reach)
        let before = h.index.shapesJudged
        h.writer.replace(words[0], with: reworded, in: .shape(task))
        h.settle()
        expectEqual(queries.standingWholeAsks, whole, "a reworded constraint asks no whole file")
        expect(h.index.shapesJudged - before <= 12, "its frame's members: \(h.index.shapesJudged - before)")
    },
    test("a type renamed and its list written in one commit is heard; an untitled type's label is Untitled") {
        let h = try typeConstraintHarness()
        let task = h.type("Task")
        let backlog = h.frame("Backlog", CGRect(x: 40, y: 40, width: 400, height: 300), of: [task])
        h.settle()
        let schema = TypeConstraintBook.text(try require(h.editor.schema(task)), setting: [onlyTasks])
        h.editor.transact("Both") {
            $0.update(task) {
                $0[TitleProperty.self] = "Chore"
                $0[TypeSchemaProperty.self] = SchemaText(schema ?? "")
            }
        }
        h.settle()
        expectEqual(h.index.sources(of: .shape(backlog)).map(\.holder), [task])
        expectEqual(h.index.constraints(of: .shape(backlog)).map(\.constraint), [onlyTasks])
    },
])

// The Rules tab of a type that is built on others: their lists under their pills, dimmed, from `TypeConstraints.sources(of:)`.

/// The detail panel alone in an unshown window over a harness's editor, and the words it shows.
@MainActor final class RulesWindow {
    let h: EditorHarness
    let window: NSWindow
    let hosting: NSView

    init(_ h: EditorHarness) {
        self.h = h
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: DetailPanelView(editor: h.editor, onExit: {}).environment(\.locale, Locale(identifier: "en_US")))
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        window.contentView = hosting
        window.settle()
    }

    func show(_ id: ShapeID) throws {
        let record = try require(h.editor.document[id])
        h.editor.detailPanel?.choose(.of(RulesTab.self), for: record.kind)
        h.editor.selectedShapeIDs = [id]
        land()
    }

    func land() {
        for _ in 0..<5 {
            window.settle()
            h.scheduler.advance(by: .milliseconds(100))
        }
    }

    /// The panel's text views below its header, in reading order: here the box that adds a constraint and each own row's.
    var boxes: [NSTextView] { hosting.descendants(NSTextView.self).filter { !$0.isFieldEditor && $0.convert($0.bounds, to: hosting).maxY > 44 } }

    /// The panel's buttons below its header, a pop-up not one: the pill another type's list is shown under, and each own row's remove.
    var pills: [NSButton] {
        hosting.descendants(NSButton.self).filter { !($0 is NSPopUpButton) && $0.convert($0.bounds, to: nil).maxY < window.contentLayoutRect.maxY - 44 }
    }

    /// How far down the box that adds a constraint is: what is shown above it moves it.
    var addY: CGFloat { boxes.last.map { $0.convert($0.bounds, to: hosting).minY } ?? 0 }
}

@MainActor let typeConstraintPanelTests = Suite("A type's constraints in its Rules tab", [
    test("a type built on another shows that type's list under its pill, dimmed, above its own rows, and follows the list as it changes") {
        let h = try typeConstraintHarness([QueryTranslationPlugin(prompt: "Write a query for the words.", referenceRule: "The query is stored and run later.",
                                                                accepts: "The words name which shapes {holder} accepts."), ConstraintFacesPlugin()])
        let work = h.type("Work", [onlyWork]), task = h.type("Task", on: [work])
        h.settle()
        let panel = RulesWindow(h)
        defer { panel.window.close() }
        try panel.show(task)
        let layout = try require(h.editor.detailPanel).layout(for: require(h.editor.document[task]))
        expectEqual(layout.sections(in: .of(RulesTab.self)).map(\.section), ["holder-constraints"], "a type with no list of its own still has the section")
        panel.window.spin { !panel.boxes.isEmpty }
        let sources = try require(h.editor.typeConstraints).sources(of: task)
        expectEqual(sources.map(\.holder), [work])
        expectEqual(panel.pills.count, 1, "Work's pill, with its list under it")
        let withOne = panel.addY
        // Work's list as it changes, with no commit to Task: a constraint added makes room above the box that adds one, and
        // the list taken away takes the pill with it.
        h.writer.add(noBugs, to: .shape(work))
        h.settle()
        panel.land()
        expect(panel.addY != withOne, "live as Work's list grows: the add box moves")
        expectEqual(panel.pills.count, 1)
        h.writer.removeAll(from: .shape(work))
        h.settle()
        panel.land()
        expectEqual(panel.pills.count, 0, "Work holds none: nothing under its pill")
        expect(panel.addY < withOne, "and the add box is where it was with none")
        h.writer.add(onlyWork, to: .shape(work))
        h.settle()
        panel.land()
        expectEqual(panel.pills.count, 1, "and back")
        // The pill goes to the type it names.
        h.editor.selectedShapeIDs = [task]
        let pill = try require(panel.pills.first)
        pill.performClick(nil)
        h.scheduler.advance(by: .zero)
        expectEqual(h.editor.selectedShapeIDs, [work], "the pill goes to Work")
        // Work itself, built on nothing, has nothing from elsewhere; Task's own list is rows of its own beside Work's.
        try panel.show(work)
        expectEqual(panel.pills.count, 1, "Work's own row's remove button, and no pill for itself")
        h.writer.add(onlyTasks, to: .shape(task))
        h.settle()
        try panel.show(task)
        expectEqual(panel.pills.count, 2, "Work's pill, and the remove button of Task's own row")
        expectEqual(panel.boxes.map(\.string), [":is-a(\"Work\")", "only tasks", ":is-a(\"Task\")", ""], "Work's query read-only, as a frame's section shows one, then its own row's words and query, the add box")
        // The list from Work comes first, as a frame's section has it: its pill is above Task's own first row.
        let pillButton = try require(panel.pills.min { $0.convert($0.bounds, to: panel.hosting).minY < $1.convert($1.bounds, to: panel.hosting).minY })
        let pillTop = pillButton.convert(pillButton.bounds, to: panel.hosting).minY
        let ownBox = try require(panel.boxes.dropFirst().first)
        let ownTop = ownBox.convert(ownBox.bounds, to: panel.hosting).minY
        expect(pillTop < ownTop, "Work's pill (\(pillTop)) is above Task's own row (\(ownTop))")
    },
])
