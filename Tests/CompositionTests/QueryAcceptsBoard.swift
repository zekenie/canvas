import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Colors
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import Queries
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles
import Types

// The live evaluation's fifth file (scripts/query-prompts, QueryLiveTests), for the words that say what a container
// accepts ("only tasks", "no bugs": `TranslationContext.accepting`): three types and notes of them on the top board, plain
// notes, one of them blue, and two subboards, with fixed ids, `00000000-0000-4000-8000-0000000A00NN`. A case is scored by
// the shapes the query the words become matches on this file, wherever they are.
//
//     Task    …01  a type: name (titles the note), status (todo, doing or done)
//     Bug     …02  a type: name, status (todo, doing or done)
//     Person  …03  a type: name, email (text)
//
//     Tasks: Write docs (todo), Fix login (doing), Ship v2 (done). Bugs: Crash on save (todo), Slow search (done).
//     People: Ann (email), Bo (none). Plain notes: Meeting notes, Idea, Sky idea (blue). Subboards: Archive, Design.

/// The evaluation's fifth file: its shapes' ids, and the file (`file(in:)`) in an editor of the shipped plugins.
@MainActor
enum QueryAcceptsBoard {
    /// `…A00NN`: the file's id for `nn`.
    static func id(_ nn: UInt8) -> ShapeID {
        ShapeID(UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000A00%02X", nn))!)
    }

    static let task = id(0x01), bug = id(0x02), person = id(0x03)
    static let writeDocs = id(0x11), fixLogin = id(0x12), shipV2 = id(0x13)
    static let crashOnSave = id(0x21), slowSearch = id(0x22)
    static let ann = id(0x31), bo = id(0x32)
    static let meetingNotes = id(0x41), idea = id(0x42), skyIdea = id(0x43)
    static let archive = id(0x51), design = id(0x52)

    static let taskSchema = """
        {"type": "object", "properties": {"name": {"type": "string"}, \
        "status": {"type": "string", "enum": ["todo", "doing", "done"]}, "$title": {"x-canvas-from": "name"}}, "required": ["name"]}
        """
    static let bugSchema = taskSchema
    static let personSchema = """
        {"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}, \
        "$title": {"x-canvas-from": "name"}}, "required": ["name"]}
        """

    /// The file: every shape on the top board, five to a row.
    static func file(in registry: Registry) -> CanvasFile {
        var place = 0
        func note(_ id: ShapeID, _ title: String, _ text: String = "") -> ShapeRecord<StickyNote> {
            defer { place += 1 }
            let origin = CGPoint(x: 80 + (place % 5) * 320, y: 80 + (place / 5) * 320)
            var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: MentionText(plain: text)))
            note[TitleProperty.self] = title
            return note
        }
        func type(_ id: ShapeID, _ title: String, _ schema: String) -> AnyShapeRecord {
            var record = note(id, title)
            record[TypeSchemaProperty.self] = SchemaText(schema)
            return AnyShapeRecord(record)
        }
        func instance(_ id: ShapeID, _ title: String, of type: ShapeID, _ values: JSONObject) -> AnyShapeRecord {
            var record = note(id, title)
            record[IsAProperty.self] = [TypeLink(type)]
            record[FieldValuesProperty.self] = FieldValues(["name": .string(title)].merging(values) { $1 })
            return AnyShapeRecord(record)
        }
        func plain(_ id: ShapeID, _ title: String, color: ShapeColor? = nil) -> AnyShapeRecord {
            var record = note(id, title)
            if let color { record[ColorProperty.self] = color }
            return AnyShapeRecord(record)
        }
        func subboard(_ id: ShapeID, _ title: String) -> AnyShapeRecord {
            let origin = CGPoint(x: 80 + (place % 5) * 320, y: 80 + (place / 5) * 320)
            place += 1
            var record = ShapeRecord(id: id, Subboard(frame: CGRect(origin: origin, size: Subboard.defaultSize)))
            record[TitleProperty.self] = title
            return AnyShapeRecord(record)
        }
        let shapes: [AnyShapeRecord] = [
            type(task, "Task", taskSchema), type(bug, "Bug", bugSchema), type(person, "Person", personSchema),
            instance(writeDocs, "Write docs", of: task, ["status": "todo"]),
            instance(fixLogin, "Fix login", of: task, ["status": "doing"]),
            instance(shipV2, "Ship v2", of: task, ["status": "done"]),
            instance(crashOnSave, "Crash on save", of: bug, ["status": "todo"]),
            instance(slowSearch, "Slow search", of: bug, ["status": "done"]),
            instance(ann, "Ann", of: person, ["email": "ann@example.com"]),
            instance(bo, "Bo", of: person, [:]),
            plain(meetingNotes, "Meeting notes"), plain(idea, "Idea"), plain(skyIdea, "Sky idea", color: .named("blue")),
            subboard(archive, "Archive"), subboard(design, "Design"),
        ]
        return CanvasFile(root: CanvasDocument(shapes: shapes), children: [archive: CanvasDocument(shapes: []), design: CanvasDocument(shapes: [])])
    }
}

@MainActor let queryAcceptsBoardTests = Suite("Query accepts board", [
    test("the accepts board: three types, their notes, plain notes with a blue one, and two subboards, every value as its type has it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let h = EditorHarness { CanvasEditor(registry: registry, file: QueryAcceptsBoard.file(in: registry), scheduler: $0) }
        let queries = try require(h.editor.queries)
        @MainActor func ids(_ query: String) throws -> Set<ShapeID> {
            Set(try awaitResult { try await queries.run(QueryRequest(query, limit: QueryRequest.every, properties: .none)) }.rows.map(\.id))
        }
        typealias A = QueryAcceptsBoard
        expectEqual(try ids(#":is-a("Task")"#), [A.writeDocs, A.fixLogin, A.shipV2])
        expectEqual(try ids(#":is-a("Bug")[fieldValues.status="done"]"#), [A.slowSearch])
        expectEqual(try ids(#":is-a("Person")[fieldValues.email]"#), [A.ann])
        expectEqual(try ids("[color=blue]"), [A.skyIdea])
        expectEqual(try ids("subboard"), [A.archive, A.design])
        expectEqual(try ids("sticky-note[schema]"), [A.task, A.bug, A.person])
        expectEqual(try ids(":invalid"), [], "every value as its type has it")
    },
])
