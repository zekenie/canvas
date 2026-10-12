@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Types
import Validation

// The check of a pointer: a value that isn't a link to a note is wrong, a link to a note that is gone is a
// warning, one to a note that is no longer of the type is wrong. The pure part (`FieldChecker.linkProblems`,
// a state handed in), and the service's (the states read from the editor, kept right when a target changes).

private let person = FieldFixtures.personID, order = FieldFixtures.orderID, employee = FieldFixtures.employeeID
private let ann = FieldFixtures.annLeeID, bo = FieldFixtures.boParkID

/// A type with a pointer at every depth: a field, a member of a group, a list of pointers and a cell of a table.
private func teamSchema(_ type: ShapeID) -> String {
    let pointer = String(decoding: try! JSONEncoder().encode(JSONValue.object(FieldKind.pointerSchema(to: type))), as: UTF8.self)
    return #"""
    {"type": "object", "properties": {
      "lead": \#(pointer),
      "squad": {"type": "object", "properties": {"captain": \#(pointer), "name": {"type": "string"}}},
      "crew": {"type": "array", "items": \#(pointer)},
      "rows": {"type": "array", "items": {"type": "object", "properties": {"name": {"type": "string"}, "who": \#(pointer)}}},
      "note": {"type": "string"}
    }, "required": ["note"]}
    """#
}

private func className(_ kind: FieldClass) -> String {
    switch kind {
    case .warning: "warning"
    case .needed: "needed"
    case .wrong: "wrong"
    }
}

private func summary(_ check: FieldCheck) -> [String] {
    check.problems.map { "\(className($0.kind)) \($0.path.isRoot ? "(root)" : $0.path.pointer)" }
}

@MainActor private func checker(_ editor: CanvasEditor, _ type: ShapeID) throws -> FieldChecker {
    try require(FieldChecker(types: [type], book: try require(editor.fieldBook)))
}

@MainActor private func team(_ editor: CanvasEditor, pointingAt type: ShapeID = person, title: String? = "Team") -> ShapeID {
    editor.addType(teamSchema(type), title: title)
}

private func values(_ object: JSONObject) -> FieldValues { FieldValues(object) }

@MainActor private func check(of id: ShapeID, in editor: CanvasEditor) -> FieldCheck {
    guard let record = editor.file.record(id), let checks = editor.fieldChecks else { return .clean }
    return checks.fullCheck(of: record)
}

/// Counts the shapes the engine asks every rule of.
@MainActor private final class Probe {
    var asked: [ShapeID] = []
}

private struct ProbePlugin: CanvasPlugin {
    let probe: Probe
    var id: PluginID { "link-probe" }
    func register(into registrar: inout PluginRegistrar) {
        let probe = probe
        registrar.validateEveryShape { shape, _ in
            probe.asked.append(shape.id)
            return []
        }
    }
}

/// A service installed before Types': when Ann is deleted, it renames Bo while hearing that commit, so Types hears the
/// rename before the delete.
private struct RenamerPlugin: CanvasPlugin {
    let renamer: Renamer
    var id: PluginID { "link-renamer" }
    func register(into registrar: inout PluginRegistrar) {
        let renamer = renamer
        registrar.service { _ in renamer }
    }
}

@MainActor private final class Renamer {
    var armed = false
}

extension Renamer: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard armed, changes.removed.contains(ann) else { return }
        armed = false
        editor.transact("Rename") { $0.update(bo) { $0[TitleProperty.self] = "Bo Parker" } }
    }
}

@MainActor let fieldLinkCheckerTests = Suite("The check of a pointer, pure", [
    test("each state of a target: one is clean, gone a warning with the name it holds, no longer one wrong with the name it shows, elsewhere nothing") {
        let editor = try fieldEditor()
        let type = team(editor)
        let checker = try checker(editor, type)
        let value = values(["lead": link(to: ann, "Ann")])
        expectEqual(checker.linkProblems(in: value) { _, _ in .one }, [])
        expectEqual(checker.linkProblems(in: value) { _, _ in .elsewhere }, [])
        let gone = checker.linkProblems(in: value) { _, _ in .gone }
        expectEqual(gone.map(\.kind), [.warning])
        expectEqual(gone.map(\.message), ["lead links to “Ann”, which is gone"], "the stored name, not the title she has")
        expectEqual(gone.map(\.keyword), ["link"])
        expectEqual(gone.map(\.path), [FieldPath(field: "lead")])
        let notOne = checker.linkProblems(in: value) { _, _ in .notOne }
        expectEqual(notOne.map(\.kind), [.wrong])
        expectEqual(notOne.map(\.message), ["lead links to “Ann Lee”, which isn’t a Person"], "the live name")
        expectEqual(checker.linkProblems(in: values(["lead": link(to: ann, "")])) { _, _ in .gone }.map(\.message), ["lead links to “a note”, which is gone"])
    },

    test("a value that is not exactly one token is wrong, whatever the state says") {
        let editor = try fieldEditor()
        let checker = try checker(editor, team(editor))
        let found = checker.linkProblems(in: values(["lead": "Ann Lee", "crew": .array(["Bo", link(to: bo, "Bo Park")])])) { _, _ in .one }
        expectEqual(found.map(\.kind), [.wrong, .wrong])
        expectEqual(Set(found.map(\.path)), [FieldPath(field: "lead"), FieldPath(field: "crew").index(0)])
        expect(found.allSatisfy { $0.keyword == "link" })
        expect(found.map(\.message).contains("lead isn’t a link to a Person"), "\(found.map(\.message))")
        expectEqual(checker.linkProblems(in: values(["lead": 3])) { _, _ in .one }.map(\.kind), [.wrong], "a number")
    },

    test("a pointer in a group, in a list, and in a table's cell is found at its path and placed by the rows' names") {
        let editor = try fieldEditor()
        let checker = try checker(editor, team(editor))
        let found = checker.linkProblems(in: values(["squad": ["captain": link(to: ann, "Ann")],
                                                      "crew": .array([link(to: bo, "Bo"), link(to: ann, "Ann")]),
                                                      "rows": .array([["name": "Mug", "who": link(to: ann, "Ann")], ["name": "Plate", "who": link(to: bo, "Bo")]])])) { target, _ in
            target == bo ? .gone : .one
        }
        expectEqual(found.map(\.path.pointer), ["/crew/0", "/rows/1/who"])
        expectEqual(found.map(\.message), ["crew › item 1 links to “Bo”, which is gone", "rows › Plate › who links to “Bo”, which is gone"])
        let second = checker.linkProblems(in: values(["crew": .array([link(to: ann, "Ann"), link(to: bo, "Bo")])])) { target, _ in target == bo ? .gone : .one }
        expectEqual(second.map(\.path), [FieldPath(field: "crew").index(1)], "a list's second item: its index")
        let group = checker.linkProblems(in: values(["squad": ["captain": link(to: ann, "Ann")]])) { _, _ in .gone }
        expectEqual(group.map(\.path), [FieldPath(field: "squad").key("captain")])
        expectEqual(group.map(\.message), ["squad › captain links to “Ann”, which is gone"])
    },

    test("a pointer's type that is gone has no site: its values are kept and not checked; an untitled type is worded by its type") {
        let editor = try fieldEditor()
        let type = team(editor)
        let made = try checker(editor, type)
        expect(made.holdsLinks)
        editor.transact("Delete") { $0.delete([person]) }
        expectEqual(made.linkProblems(in: values(["lead": "not even a token"])) { _, _ in .notOne }, [], "the type went after the checker was made")
        let fresh = try checker(editor, type)
        expect(!fresh.holdsLinks, "no site for a type that isn't one")
        expectEqual(fresh.linkProblems(in: values(["lead": link(to: ann, "Ann")])) { _, _ in .gone }, [])

        let plain = editor.addType(TypeSchemaProperty.starter)
        let untitled = try checker(editor, team(editor, pointingAt: plain, title: "Untitled team"))
        expectEqual(untitled.linkProblems(in: values(["lead": link(to: ann, "Ann Lee")])) { _, _ in .notOne }.map(\.message), ["lead links to “Ann Lee”, which isn’t of its type"])
        expectEqual(untitled.linkProblems(in: values(["lead": "x"])) { _, _ in .one }.map(\.message), ["lead isn’t a link to a note of its type"])
    },

    test("a list with no pointer has no site, and the check of its values is the validator's alone") {
        let editor = try fieldEditor()
        let checker = try checker(editor, address)
        expect(!checker.holdsLinks)
        expectEqual(checker.linkProblems(in: values(["street": "x"])) { _, _ in .gone }, [])
    },
])

private let address = FieldFixtures.addressID

@MainActor let fieldLinkChecksTests = Suite("The check of a pointer, in the service", [
    test("a note that points at a live Person is clean; at a deleted one, a warning, with no commit on the note; undone, clean") {
        let editor = try fieldEditor()
        let note = editor.addNote(of: [order], ["customer": link(to: ann, "Ann Lee"), "lineItems": [["product": "Mug", "quantity": 1]]])
        expectEqual(summary(check(of: note, in: editor)), [])
        let revision = editor.document[note]
        editor.transact("Delete") { $0.delete([ann]) }
        expectEqual(editor.document[note], revision, "nothing written to the Order")
        let gone = check(of: note, in: editor)
        expectEqual(summary(gone), ["warning /customer"])
        expectEqual(gone.problems.map(\.message), ["customer links to “Ann Lee”, which is gone"])
        expect(gone.hasWarnings && !gone.isWrong && !gone.isIncomplete)
        expectEqual(gone.mark(at: FieldPath(field: "customer")), .warning)
        editor.undo()
        expectEqual(summary(check(of: note, in: editor)), [])
    },

    test("a cut and a paste: a warning between, clean after; a delete rechecks the carriers and not the notes that point elsewhere") {
        let probe = Probe()
        let editor = try fieldEditor(more: [ProbePlugin(probe: probe)])
        let pointing = editor.addNote(of: [order], ["customer": link(to: ann, "Ann Lee"), "lineItems": [["product": "Mug", "quantity": 1]]])
        let other = editor.addNote(of: [order], ["customer": link(to: bo, "Bo Park"), "lineItems": [["product": "Mug", "quantity": 1]]])
        let bystander = editor.addNote(of: [person], ["email": "ann@example.com", "name": "Cy"])
        _ = (check(of: pointing, in: editor), check(of: other, in: editor))
        _ = editor.validation?.results
        probe.asked = []
        let record = try require(editor.document[ann])
        editor.transact("Cut") { $0.delete([ann]) }
        _ = editor.validation?.results
        let asked = Set(probe.asked)
        expect(asked.contains(pointing), "the Order that points at her is rechecked")
        expect(!asked.contains(other) && !asked.contains(bystander), "and no other: \(asked)")
        expectEqual(summary(check(of: pointing, in: editor)), ["warning /customer"])
        expect(editor.validation?.result(for: pointing)?.issues.map(\.severity) == [.warning], "the ring is orange: \(String(describing: editor.validation?.result(for: pointing)))")
        expectEqual(summary(check(of: other, in: editor)), [])
        editor.transact("Paste") { $0.insert(record) }
        expectEqual(summary(check(of: pointing, in: editor)), [], "back by the same id")
        _ = editor.validation?.results
        expectEqual(editor.validation?.result(for: pointing)?.issues ?? [], [])
    },

    test("a Person moved onto another board: no carrier, no recheck, no check made again, and still clean") {
        let probe = Probe()
        let editor = try fieldEditor(more: [PocketsPlugin(), ProbePlugin(probe: probe)])
        let pocket = editor.add(Pocket(CGRect(x: 800, y: 1400, width: 100, height: 100)))
        let note = editor.addNote(of: [order], ["customer": link(to: ann, "Ann Lee"), "lineItems": [["product": "Mug", "quantity": 1]]])
        let checks = try require(editor.fieldChecks)
        expectEqual(summary(check(of: note, in: editor)), [])
        _ = editor.validation?.results
        probe.asked = []
        let made = (checks.checksMade, checks.linkChecksMade)
        editor.transact("Move") { $0.move([ann], toBoardOwnedBy: pocket) }
        _ = editor.validation?.results
        expect(!probe.asked.contains(note), "the Order is not asked again")
        expectEqual(summary(check(of: note, in: editor)), [])
        expectEqual(checks.checksMade, made.0)
        expectEqual(checks.linkChecksMade, made.1, "the pointers' part is not made again")
        expectEqual(try require(editor.fieldBook).resolution(of: try require(FieldLink(link(to: ann, "Ann Lee")))).isLive, true)
    },

    test("a Person that loses Person, or becomes a type, is wrong; Employee stopping building on Person reaches the Order though it is no instance of it") {
        let editor = try fieldEditor()
        let note = editor.addNote(of: [order], ["customer": link(to: ann, "Ann Lee"), "lineItems": [["product": "Mug", "quantity": 1]]])
        expectEqual(summary(check(of: note, in: editor)), [])
        editor.removeTypeLink(person, from: ann)
        let lost = check(of: note, in: editor)
        expectEqual(summary(lost), ["wrong /customer"])
        expectEqual(lost.problems.map(\.message), ["customer links to “Ann Lee”, which isn’t a Person"])
        editor.addTypeLink(person, to: ann)
        expectEqual(summary(check(of: note, in: editor)), [])
        editor.makeType(ann)
        expectEqual(summary(check(of: note, in: editor)), ["wrong /customer"], "a type's own note is no target")
        editor.removeType(ann)
        expectEqual(summary(check(of: note, in: editor)), [])

        // A Cy who is an Employee, who is a Person: the Order is clean until Employee stops building on Person.
        let probe = Probe()
        let probed = try fieldEditor(more: [ProbePlugin(probe: probe)])
        let annAgain = probed.addInstance("", of: [employee], title: "Cy Doe")
        let pointing = probed.addNote(of: [order], ["customer": link(to: annAgain, "Cy Doe"), "lineItems": [["product": "Mug", "quantity": 1]]])
        expectEqual(summary(check(of: pointing, in: probed)), [])
        _ = probed.validation?.results
        probe.asked = []
        probed.removeTypeLink(person, from: employee)
        _ = probed.validation?.results
        expect(probe.asked.contains(pointing), "rechecked though it was no instance of what changed")
        expectEqual(summary(check(of: pointing, in: probed)), ["wrong /customer"])
    },

    test("a rename of the Person follows in the message; typing in her words below her first line moves nothing") {
        let probe = Probe()
        let editor = try fieldEditor(more: [ProbePlugin(probe: probe)])
        let note = editor.addNote(of: [order], ["customer": link(to: ann, "Ann Lee")])
        let unrelated = editor.addNote(of: [person], ["name": "Cy"])
        editor.removeTypeLink(person, from: ann)
        expectEqual(check(of: note, in: editor).problems.first { $0.keyword == "link" }?.message, "customer links to “Ann Lee”, which isn’t a Person")
        editor.transact("Rename") { $0.update(ann) { $0[TitleProperty.self] = "Ann Smith" } }
        expectEqual(check(of: note, in: editor).problems.first { $0.keyword == "link" }?.message, "customer links to “Ann Smith”, which isn’t a Person")

        // Her words, edited below the first line: her name is the title, so nothing the check reads moved.
        let checks = try require(editor.fieldChecks)
        editor.addTypeLink(person, to: ann)
        _ = check(of: note, in: editor)
        _ = editor.validation?.results
        probe.asked = []
        let made = checks.linkChecksMade
        let revision = try require(editor.fieldBook).linkRevision(of: ann)
        editor.transact("Type") { $0.update(ann, as: Memo.self) { $0.props.text = MentionText(plain: "Ann\nlikes tea") } }
        _ = editor.validation?.results
        expectEqual(try require(editor.fieldBook).linkRevision(of: ann), revision, "no target bumped")
        expect(!probe.asked.contains(note), "no carrier rechecked")
        _ = check(of: note, in: editor)
        expectEqual(checks.linkChecksMade, made, "no pointer part made again")
        // A keystroke in an unrelated note bumps no target.
        editor.transact("Type") { $0.update(unrelated, as: Memo.self) { $0.props.text = "x" } }
        expectEqual(try require(editor.fieldBook).linkRevision(of: ann), revision)
    },

    test("a drag of pointing notes and targets reads and checks nothing; a file put in place drops what the book kept") {
        let editor = try fieldEditor()
        let note = editor.addNote(of: [order], ["customer": link(to: ann, "Ann Lee"), "lineItems": [["product": "Mug", "quantity": 1]]])
        let checks = try require(editor.fieldChecks)
        _ = check(of: note, in: editor)
        let made = (checks.checksMade, checks.linkChecksMade)
        editor.transact("Move") { $0.translate([note, ann], by: CGPoint(x: 10, y: 10)) }
        _ = check(of: note, in: editor)
        expectEqual((checks.checksMade, checks.linkChecksMade).0, made.0)
        expectEqual((checks.checksMade, checks.linkChecksMade).1, made.1)
        let book = try require(editor.fieldBook)
        expect(book.tracksTargets)
        editor.replaceFile(with: editor.file)
        expect(!book.tracksTargets, "a file put in place: the book kept another file's")
        expectEqual(summary(check(of: note, in: editor)), [])
        expect(book.tracksTargets, "and asking again remembers")
    },

    test("a target kept aside is neither warned nor wrong, and an answer's pointers are made once however often it is asked") {
        let editor = try fieldEditor()
        let note = editor.addNote(of: [order], ["customer": link(to: ann, "Ann Lee"), "lineItems": [["product": "Mug", "quantity": 1]]])
        let checks = try require(editor.fieldChecks)
        let before = checks.linkChecksMade
        for _ in 0..<5 { _ = check(of: note, in: editor) }
        expectEqual(checks.linkChecksMade - before, 1)
    },

    test("a field called stands-for holding a pointer is checked right whenever it is read, but no edge finds it: Validation does not look again when its target goes (pinned: the lag)") {
        let probe = Probe()
        let editor = try fieldEditor(more: [ProbePlugin(probe: probe)])
        let pointer = String(decoding: try JSONEncoder().encode(JSONValue.object(FieldKind.pointerSchema(to: person))), as: UTF8.self)
        let type = editor.addType(#"{"type": "object", "properties": {"stands-for": \#(pointer)}}"#, title: "Odd")
        let note = editor.addNote(of: [type], ["stands-for": link(to: ann, "Ann Lee")])
        expectEqual(summary(check(of: note, in: editor)), [])
        _ = editor.validation?.results
        probe.asked = []
        editor.transact("Delete") { $0.delete([ann]) }
        _ = editor.validation?.results
        expect(!probe.asked.contains(note), "no field-link edge names her, so no carrier is found")
        expectEqual(summary(check(of: note, in: editor)), ["warning /stands-for"], "the answer itself follows the target's revision")
    },

    test("a pointer first checked while its type is gone is checked once the type comes back, and the ring follows") {
        let editor = try fieldEditor()
        let note = editor.addNote(of: [order], ["customer": "not a link", "lineItems": [["product": "Mug", "quantity": 1]]])
        let twin = editor.addNote(of: [order], ["customer": "not a link either", "lineItems": [["product": "Mug", "quantity": 1]]])
        editor.transact("Delete") { $0.delete([person]) }
        expectEqual(summary(check(of: note, in: editor)), [], "a gone type: its values kept and not checked")
        _ = editor.validation?.results
        expectEqual(editor.validation?.result(for: note)?.issues ?? [], [], "no red under a gone type")
        editor.undo()
        _ = editor.validation?.results
        expectEqual(summary(check(of: twin, in: editor)), ["wrong /customer"], "the first asked after the undo")
        expectEqual(summary(check(of: note, in: editor)), ["wrong /customer"], "and the next, its list's checker found again")
        expectEqual(editor.validation?.result(for: note)?.issues.map(\.severity), [.error], "Validation was told")
    },

    test("a wrong pointer's answer goes when its type goes, though its value names no target, and Validation is told") {
        let editor = try fieldEditor()
        let note = editor.addNote(of: [order], ["customer": "not a link", "lineItems": [["product": "Mug", "quantity": 1]]])
        expectEqual(summary(check(of: note, in: editor)), ["wrong /customer"])
        _ = editor.validation?.results
        expectEqual(editor.validation?.result(for: note)?.issues.map(\.severity), [.error])
        editor.transact("Delete") { $0.delete([person]) }
        _ = editor.validation?.results
        expectEqual(summary(check(of: note, in: editor)), [], "values under a gone type are kept and not checked")
        expectEqual(editor.validation?.result(for: note)?.issues ?? [], [], "no note turns red")
        editor.undo()
        _ = editor.validation?.results
        expectEqual(summary(check(of: note, in: editor)), ["wrong /customer"])
        expectEqual(editor.validation?.result(for: note)?.issues.map(\.severity), [.error])
    },

    test("a target deleted in a commit heard out of turn, after one a service made while hearing it, is found, and its undo too") {
        let renamer = Renamer()
        let editor = CanvasEditor(registry: try Registry(plugins: [RenamerPlugin(renamer: renamer)] + typePlugins()),
                                  file: CanvasFile(root: CanvasDocument()), scheduler: ManualScheduler())
        editor.addFieldTypes([FieldFixtures.person, FieldFixtures.address, FieldFixtures.employee, FieldFixtures.order])
        for (id, name, place) in [(ann, "Ann Lee", 0.0), (bo, "Bo Park", 1.0)] {
            let record = instanceRecord("", of: [person], title: name, at: CGPoint(x: 40 + place * 300, y: 1400), id: id)
            editor.transact("Add Person") { $0.insert(record) }
        }
        let note = editor.addNote(of: [order], ["customer": link(to: ann, "Ann Lee"), "lineItems": [["product": "Mug", "quantity": 1]]])
        let other = editor.addNote(of: [order], ["customer": link(to: bo, "Bo Park"), "lineItems": [["product": "Mug", "quantity": 1]]])
        expectEqual(summary(check(of: note, in: editor)), [])
        expectEqual(summary(check(of: other, in: editor)), [])
        let book = try require(editor.fieldBook)
        let (annSeen, boSeen) = (book.linkRevision(of: ann), book.linkRevision(of: bo))
        renamer.armed = true
        let before = editor.revision
        editor.transact("Delete") { $0.delete([ann]) }
        expectEqual(editor.revision, before + 2, "the delete, and the rename made while hearing it")
        expect(book.linkRevision(of: ann) != annSeen, "the delete, heard after the rename, is read for itself")
        expect(book.linkRevision(of: bo) != boSeen, "and the rename for itself")
        expectEqual(summary(check(of: note, in: editor)), ["warning /customer"])
        while editor.file.record(ann) == nil, editor.canUndo { editor.undo() }
        expectEqual(summary(check(of: note, in: editor)), [], "Ann is back")
        _ = editor.validation?.results
        expectEqual(editor.validation?.result(for: note)?.issues ?? [], [])
        expect(try require(editor.fieldBook).resolution(of: try require(FieldLink(link(to: ann, "Ann Lee")))).isLive, "her pill is live again")
    },

    test("a note's problems are capped at 100 keeping one of each class, a warning among them") {
        let editor = try fieldEditor()
        let type = team(editor)
        let many = JSONValue.array((0..<150).map { _ in "x" } + [link(to: ShapeID(), "Gone")])
        let id = editor.addNote(of: [type], ["crew": many])
        let found = check(of: id, in: editor)
        expectEqual(found.problems.count, 100)
        expect(found.isWrong && found.isIncomplete && found.hasWarnings, "a wrong, the needed note and the warning are each kept: \(summary(found).suffix(3))")
    },
])
