import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Connections
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import Queries
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles
import Types

// The live evaluation's fourth file (scripts/query-prompts, QueryLiveTests), for questions that cross two
// relationships and test a field at the far end ("all teachers who have students who have a blue pet beta
// fish", the owner's own words): three types, two relationship types and their notes on the top board, and a
// subboard of plain notes and arrows saying the same kind of thing in words, with fixed ids,
// `00000000-0000-4000-8000-0000000C00NN`. Each note's `is` and `fieldValues` are set on its record.
//
//     Teacher  …01  a type: name (titles the note), subject (math, science or art)
//     Student  …02  a type: name, grade (a number)
//     Pet      …03  a type: name, species (dog, cat, beta fish, goldfish, lizard or hamster), color (text)
//     Teaches  …04  a relationship type from a Teacher to a Student (period, a number); ends named students
//                   and teachers
//     Has pet  …05  a relationship type from a Student to a Pet (since, a date); ends named pets and owner
//
//     Ms. Frizzle (science) teaches Arnold, Wanda, Carlos and Ralphie; Mr. Keating (art) teaches Carlos and
//     Neil; Ms. Honey (math) teaches Matilda; Zoe has no teacher. Grades: Arnold, Wanda and Ralphie 3, Carlos
//     4, Neil 5, Matilda 2, Zoe 1.
//     Arnold has Liz (lizard, green), Wanda Bubbles (beta fish, blue), Carlos Finn (beta fish, red), Neil Rex
//     (dog, blue), Matilda Tibbles (cat, black), Zoe Sky (beta fish, blue); Ralphie has none.
//
// So the owner's question is Ms. Frizzle alone: Keating's Carlos has a red beta fish and his Neil a blue dog,
// and Zoe's blue beta fish has no teacher.
//
//     After school …71  a subboard of plain notes: Coach Lee ("Runs the swim team") → Sam → Goldie ("Sam's
//                       axolotl, pink"), Coach Lee → Pia → Nibbles ("Pia's rabbit, white"), plain arrows: animals no
//                       Pet's species names, so a question about them is one of words and arrows, not of a type's field

/// The evaluation's fourth file: its shapes' ids, and the file (`file(in:)`) in an editor of the shipped
/// plugins (`harness`).
@MainActor
enum QuerySchoolBoard {
    /// `…C00NN`: the file's id for `nn`.
    static func id(_ nn: UInt8) -> ShapeID {
        ShapeID(UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000C00%02X", nn))!)
    }

    static let teacher = id(0x01), student = id(0x02), pet = id(0x03), teaches = id(0x04), hasPet = id(0x05)
    static let frizzle = id(0x11), keating = id(0x12), honey = id(0x13)
    static let arnold = id(0x21), wanda = id(0x22), carlos = id(0x23), ralphie = id(0x24), neil = id(0x25), matilda = id(0x26), zoe = id(0x27)
    static let liz = id(0x31), bubbles = id(0x32), finn = id(0x33), rex = id(0x34), tibbles = id(0x35), sky = id(0x36)
    /// The relationship types' ends.
    static let teachesFrom = id(0x41), teachesTo = id(0x42), hasPetFrom = id(0x43), hasPetTo = id(0x44)
    static let afterSchool = id(0x71)
    static let coachLee = id(0x81), sam = id(0x82), pia = id(0x83), goldie = id(0x84), nibbles = id(0x85)

    /// Who teaches whom, and whose pet is whose: (from, to, the arrow's id).
    static let teaching: [(ShapeID, ShapeID, ShapeID)] = [
        (frizzle, arnold, id(0x51)), (frizzle, wanda, id(0x52)), (frizzle, carlos, id(0x53)), (frizzle, ralphie, id(0x54)),
        (keating, carlos, id(0x55)), (keating, neil, id(0x56)), (honey, matilda, id(0x57)),
    ]
    static let owning: [(ShapeID, ShapeID, ShapeID)] = [
        (arnold, liz, id(0x61)), (wanda, bubbles, id(0x62)), (carlos, finn, id(0x63)), (neil, rex, id(0x64)),
        (matilda, tibbles, id(0x65)), (zoe, sky, id(0x66)),
    ]
    /// The subboard's plain arrows: (from, to, the arrow's id).
    static let plain: [(ShapeID, ShapeID, ShapeID)] = [
        (coachLee, sam, id(0x91)), (coachLee, pia, id(0x92)), (sam, goldie, id(0x93)), (pia, nibbles, id(0x94)),
    ]

    static let teacherSchema = """
        {"type": "object", "properties": {"name": {"type": "string"}, \
        "subject": {"type": "string", "enum": ["math", "science", "art"]}, "$title": {"x-canvas-from": "name"}}, \
        "required": ["name"]}
        """
    static let studentSchema = """
        {"type": "object", "properties": {"name": {"type": "string"}, "grade": {"type": "number"}, \
        "$title": {"x-canvas-from": "name"}}, "required": ["name"]}
        """
    static let petSchema = """
        {"type": "object", "properties": {"name": {"type": "string"}, \
        "species": {"type": "string", "enum": ["dog", "cat", "beta fish", "goldfish", "lizard", "hamster"]}, \
        "color": {"type": "string"}, "$title": {"x-canvas-from": "name"}}, "required": ["name"]}
        """
    static let teachesSchema = """
        {"type": "object", "properties": {"period": {"type": "number"}}}
        """
    static let hasPetSchema = """
        {"type": "object", "properties": {"since": {"type": "string", "format": "date"}}}
        """

    /// The file: the types and their notes on the top board, five to a row, the subboard last of them, then the
    /// arrows; the subboard's plain notes and arrows on its board.
    static func file(in registry: Registry) -> CanvasFile {
        func note(_ id: ShapeID, _ title: String, _ text: String = "", at place: Int) -> ShapeRecord<StickyNote> {
            let origin = CGPoint(x: 80 + (place % 5) * 320, y: 80 + (place / 5) * 320)
            var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: MentionText(plain: text)))
            note[TitleProperty.self] = title
            return note
        }
        var place = 0
        func next() -> Int {
            defer { place += 1 }
            return place
        }
        func type(_ id: ShapeID, _ title: String, _ schema: String, relationship: Bool = false) -> AnyShapeRecord {
            var record = note(id, title, at: next())
            record[TypeSchemaProperty.self] = SchemaText(schema)
            if relationship { record[RelationshipProperty.self] = true }
            return AnyShapeRecord(record)
        }
        func instance(_ id: ShapeID, _ title: String, of type: ShapeID, _ values: JSONObject) -> AnyShapeRecord {
            var record = note(id, title, at: next())
            record[IsAProperty.self] = [TypeLink(type)]
            record[FieldValuesProperty.self] = FieldValues(["name": .string(title)].merging(values) { $1 })
            return AnyShapeRecord(record)
        }
        var subboard = ShapeRecord(id: afterSchool, Subboard(frame: CGRect(origin: CGPoint(x: 80 + (21 % 5) * 320, y: 80 + (21 / 5) * 320),
                                                                          size: Subboard.defaultSize)))
        subboard[TitleProperty.self] = "After school"
        let notes: [AnyShapeRecord] = [
            type(teacher, "Teacher", teacherSchema), type(student, "Student", studentSchema), type(pet, "Pet", petSchema),
            type(teaches, "Teaches", teachesSchema, relationship: true), type(hasPet, "Has pet", hasPetSchema, relationship: true),
            instance(frizzle, "Ms. Frizzle", of: teacher, ["subject": "science"]),
            instance(keating, "Mr. Keating", of: teacher, ["subject": "art"]),
            instance(honey, "Ms. Honey", of: teacher, ["subject": "math"]),
            instance(arnold, "Arnold", of: student, ["grade": 3]),
            instance(wanda, "Wanda", of: student, ["grade": 3]),
            instance(carlos, "Carlos", of: student, ["grade": 4]),
            instance(ralphie, "Ralphie", of: student, ["grade": 3]),
            instance(neil, "Neil", of: student, ["grade": 5]),
            instance(matilda, "Matilda", of: student, ["grade": 2]),
            instance(zoe, "Zoe", of: student, ["grade": 1]),
            instance(liz, "Liz", of: pet, ["species": "lizard", "color": "green"]),
            instance(bubbles, "Bubbles", of: pet, ["species": "beta fish", "color": "blue"]),
            instance(finn, "Finn", of: pet, ["species": "beta fish", "color": "red"]),
            instance(rex, "Rex", of: pet, ["species": "dog", "color": "blue"]),
            instance(tibbles, "Tibbles", of: pet, ["species": "cat", "color": "black"]),
            instance(sky, "Sky", of: pet, ["species": "beta fish", "color": "blue"]),
            AnyShapeRecord(subboard),
        ]
        /// An arrow made by the shipped connector between two of `shapes`, as a connection made by name is.
        func arrow(_ id: ShapeID, _ from: ShapeID, _ to: ShapeID, among shapes: [AnyShapeRecord], channel: ChannelID? = NoteLink.id,
                   is relation: ShapeID? = nil, says: String = "") -> AnyShapeRecord {
            let context = ShapeContext(document: CanvasDocument(shapes: shapes), registry: registry)
            guard var arrow = registry.connection(ConnectionRequest(from: from, to: to, channel: channel), in: context) else {
                preconditionFailure("the shipped connector connects \(from) to \(to)")
            }
            arrow = arrow.copy(as: id)
            if !says.isEmpty, var typed = arrow.typed(as: Arrow.self) {
                typed.props.text = MentionText(plain: says)
                arrow = AnyShapeRecord(typed)
            }
            if let relation { arrow[IsAProperty.self] = [TypeLink(relation)] }
            return arrow
        }
        let ends = [
            arrow(teachesFrom, teacher, teaches, among: notes, says: "students"), arrow(teachesTo, teaches, student, among: notes, says: "teachers"),
            arrow(hasPetFrom, student, hasPet, among: notes, says: "pets"), arrow(hasPetTo, hasPet, pet, among: notes, says: "owner"),
        ]
        let relationships = teaching.map { arrow($0.2, $0.0, $0.1, among: notes, is: teaches) }
            + owning.map { arrow($0.2, $0.0, $0.1, among: notes, is: hasPet) }
        place = 0
        let plainNotes = [
            AnyShapeRecord(note(coachLee, "Coach Lee", "Runs the swim team", at: next())), AnyShapeRecord(note(sam, "Sam", at: next())),
            AnyShapeRecord(note(pia, "Pia", at: next())), AnyShapeRecord(note(goldie, "Goldie", "Sam's axolotl, pink", at: next())),
            AnyShapeRecord(note(nibbles, "Nibbles", "Pia's rabbit, white", at: next())),
        ]
        let plainArrows = plain.map { arrow($0.2, $0.0, $0.1, among: plainNotes, channel: nil) }
        return CanvasFile(root: CanvasDocument(shapes: notes + ends + relationships),
                          children: [afterSchool: CanvasDocument(shapes: plainNotes + plainArrows)])
    }

    /// The file in an editor of the shipped plugins, their clipboard on `pasteboard` (a test's own) and
    /// their model `model`: the top board shown, in the story's viewport, nothing selected.
    static func harness(pasteboard: NSPasteboard, model: any LanguageModel = ScriptedLanguageModel()) throws -> EditorHarness {
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: model)
        let h = EditorHarness { CanvasEditor(registry: registry, file: file(in: registry), scheduler: $0) }
        h.editor.viewportDidResize(to: QueryStory.viewport)
        return h
    }
}

@MainActor let querySchoolBoardTests = Suite("Query school board", [
    test("the school board: three types and two relationship types, who teaches whom and whose pet is whose, and the after-school notes in words") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try QuerySchoolBoard.harness(pasteboard: pasteboard)
        let queries = try require(h.editor.queries)
        @MainActor func ids(_ query: String) throws -> Set<ShapeID> {
            Set(try awaitResult { try await queries.run(QueryRequest(query, limit: QueryBudget.maxRows, properties: .none)) }.rows.map(\.id))
        }
        typealias S = QuerySchoolBoard
        expectEqual(try ids("sticky-note[relationship]"), [S.teaches, S.hasPet])
        expectEqual(try ids(#":is-a("Teacher")"#), [S.frizzle, S.keating, S.honey])
        expectEqual(try ids(#":is-a("Pet")[fieldValues.species="beta fish"]"#), [S.bubbles, S.finn, S.sky])
        expectEqual(try ids(#":end-of(arrow:is-a("Teaches"):starts-at("Ms. Frizzle"))"#), [S.arnold, S.wanda, S.carlos, S.ralphie])
        // The owner's question: the teachers of the students who have a blue beta fish.
        expectEqual(try ids(#":start-of(arrow:is-a("Teaches"):ends-at(:start-of(arrow:is-a("Has pet"):ends-at(:is-a("Pet")[fieldValues.species="beta fish"][fieldValues.color="blue" i]))))"#),
                    [S.frizzle])
        expectEqual(try ids(#":is-a("Student"):not(:start-of(arrow:is-a("Has pet")))"#), [S.ralphie])
        expectEqual(try ids(#":is-a("Student"):not(:end-of(arrow:is-a("Teaches")))"#), [S.zoe])
        expectEqual(try ids(#""After school" sticky-note:edge-to(:contains("axolotl"))"#), [S.sam])
        expectEqual(try ids(#":contains("Coach"):edge-to(:edge-to(:contains("axolotl")))"#), [S.coachLee])
        expectEqual(try ids(":invalid"), [], "every value as its type has it")
    },
])
