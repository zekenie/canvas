import Adornments
import Automation
import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import DrawScript
import Drawings
import Foundation
import LanguageModels
import ShippedTesting
import TestKit

// `canvas apply` as shipped: a document drawn by key, every board it reaches in one step, again by key, and the drawing's
// record kept in the file. Run in-process, as the app's server runs `apply`.

@MainActor private func emptyEditor() -> CanvasEditor {
    ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
}

/// A document as JSON text.
private func document(_ value: JSON) -> String { value.compactText }

/// The plan's document: a type, a frame holding a note of it (typed by key, with a value), a note beside the frame that
/// mentions that note by key, and an edge between the two notes.
private func plan(bText: String = "after @[note:a]", withB: Bool = true) -> JSON {
    var nodes: [JSON] = [
        ["key": "type:Task", "kind": "sticky-note",
         "props": ["title": "Task", "schema": ["type": "object", "properties": ["owner": ["type": "string"]]], "text": "Something to do"],
         "place": ["at": [0, -400]]],
        ["key": "frame:sprint", "kind": "frame", "props": ["title": "Sprint"], "place": ["at": [0, 0], "size": [600, 400]]],
        ["key": "note:a", "in": "frame:sprint", "kind": "sticky-note",
         "props": ["title": "Write it", "is": ["type:Task"], "fieldValues": ["owner": "Ann"]], "place": ["at": [40, 60]]],
    ]
    var edges: [JSON] = []
    if withB {
        nodes.append(["key": "note:b", "kind": "sticky-note", "props": ["title": "Ship it", "text": .string(bText)], "place": ["at": [700, 0]]])
        edges.append(["from": "note:a", "to": "note:b", "props": ["text": "then"]])
    }
    return ["drawing": "Plan", "nodes": .array(nodes), "edges": .array(edges)]
}

private func verdict(_ result: DocumentResult, _ key: String) -> JSON? {
    let all = (try? JSON(encoding: result))?["nodes"]?.arrayValue ?? []
    return all.first { $0["key"]?.stringValue == key }
}

private func json(_ result: DocumentResult) -> JSON { (try? JSON(encoding: result)) ?? .null }

@MainActor let applyShippedTests = Suite("canvas apply, shipped", [
    test("a document is drawn where it says, by key, every node and the edge, in one step, and its record kept") {
        let editor = emptyEditor()
        let result = try apply(document: document(plan()), dryRun: false, on: nil, program: "canvas", in: editor)
        let said = json(result)
        expectEqual(said["nodes"]?.arrayValue?.map { $0["did"]?.stringValue }, ["created", "created", "created", "created"])
        guard let typeID = verdict(result, "type:Task")?["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(ShapeID.init),
              let frameID = verdict(result, "frame:sprint")?["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(ShapeID.init),
              let aID = verdict(result, "note:a")?["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(ShapeID.init),
              let bID = verdict(result, "note:b")?["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(ShapeID.init) else {
            expect(false, "every node has an id: \(said.compactText)")
            return
        }
        let file = editor.file
        expectEqual(file.record(frameID)?.box?.origin, CGPoint(x: 0, y: 0))
        expectEqual(file.record(frameID)?.box?.size, CGSize(width: 600, height: 400))
        expectEqual(file.record(aID)?.box?.origin, CGPoint(x: 40, y: 60), "from its frame's top-left")
        expectEqual(file.record(aID)?.container, frameID, "in its frame")
        expectEqual(file.record(bID)?.box?.origin, CGPoint(x: 700, y: 0))
        expectEqual(file.record(aID)?.propertiesJSON?["is"], .array([.string(typeID.description)]), "is: by key names the type")
        let text = file.record(bID)?.propertiesJSON?["text"]?.stringValue ?? ""
        expect(text.contains(aID.description), "the mention by key names the note: \(text)")
        expectEqual(said["edges"]?.arrayValue?.first?["did"], "created")
        expectEqual(editor.undoHistory.undoName, "Draw")
        let record = file[DrawingsProperty.self].drawings["Plan"]
        expectEqual(Set(record?.shapes.values.map(\.key) ?? []).isSuperset(of: ["type:Task", "frame:sprint", "note:a", "note:b"]), true)
        editor.undo()
        expectEqual(editor.file.shapeCount, 0, "one undo takes all of it back")
        expect(editor.file[DrawingsProperty.self].drawings.isEmpty, "and the record")
    },
    test("drawn again it is unchanged; a changed text is updated; a key gone is deleted with its edge; a shape that isn't the drawing's stays") {
        let editor = emptyEditor()
        _ = try apply(document: document(plan()), dryRun: false, on: nil, program: "canvas", in: editor)
        _ = try draw(script: #"sticky-note "Mine" right of origin (gap: 2000) below origin (gap: 0)"#, dryRun: false, reveal: false, program: "canvas", in: editor)
        let mine = editor.file
        let again = try apply(document: document(plan()), dryRun: false, on: nil, program: "canvas", in: editor)
        expectEqual(json(again)["nodes"]?.arrayValue?.map { $0["did"]?.stringValue }, ["unchanged", "unchanged", "unchanged", "unchanged"])
        expectEqual(editor.file, mine, "nothing changed")
        let changed = try apply(document: document(plan(bText: "after @[note:a], at last")), dryRun: false, on: nil, program: "canvas", in: editor)
        expectEqual(verdict(changed, "note:b")?["did"], "updated")
        expectEqual(verdict(changed, "note:a")?["did"], "unchanged")
        let gone = try apply(document: document(plan(withB: false)), dryRun: false, on: nil, program: "canvas", in: editor)
        expectEqual(json(gone)["deleted"]?.arrayValue?.compactMap { $0["key"]?.stringValue }.contains("note:b"), true)
        let titles = editor.file[.root].shapes.compactMap { $0.propertiesJSON?["title"]?.stringValue }
        expect(!titles.contains("Ship it"), "the note whose key is gone is deleted")
        expect(titles.contains("Mine"), "a shape outside the drawing stays")
    },
    test("a dry run says what it would do and changes nothing") {
        let editor = emptyEditor()
        let before = editor.file
        let result = try apply(document: document(plan()), dryRun: true, on: nil, program: "canvas", in: editor)
        expectEqual(json(result)["dryRun"], true)
        expectEqual(verdict(result, "note:a")?["did"], "created")
        expectEqual(verdict(result, "note:a")?["id"], nil, "a shape not made has no id")
        expectEqual(editor.file, before)
        expect(!editor.canUndo)
    },
    test("a person's move is said when the drawing moves it back") {
        let editor = emptyEditor()
        let first = try apply(document: document(plan()), dryRun: false, on: nil, program: "canvas", in: editor)
        guard let bID = verdict(first, "note:b")?["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(ShapeID.init) else {
            expect(false, "note:b drawn")
            return
        }
        editor.transact("Move") { tx in tx.translate([bID], by: CGPoint(x: 50, y: 30)) }
        let again = try apply(document: document(plan()), dryRun: false, on: nil, program: "canvas", in: editor)
        expectEqual(verdict(again, "note:b")?["did"], "updated")
        expectEqual(verdict(again, "note:b")?["overrode"], ["moved"])
        expectEqual(editor.file.record(bID)?.box?.origin, CGPoint(x: 700, y: 0))
    },
    test("a refusal names the key, in the app's words, and changes nothing") {
        let editor = emptyEditor()
        let before = editor.file
        var bad = plan()
        bad["nodes"] = .array((bad["nodes"]?.arrayValue ?? []) + [["key": "note:c", "in": "note:b", "kind": "sticky-note"]])
        do throws(DocumentError) {
            _ = try apply(document: document(bad), dryRun: false, on: nil, program: "canvas", in: editor)
            expect(false, "a note holds nothing")
        } catch {
            expectEqual(error.first.key, "note:c")
            expectEqual(error.reason, "cannot_contain")
        }
        var unknown = plan()
        unknown["nodes"] = .array((unknown["nodes"]?.arrayValue ?? []).map { node in
            guard node["key"] == "note:a" else { return node }
            var node = node
            node["props"]?["is"] = ["type:Nothing"]
            return node
        })
        do throws(DocumentError) {
            _ = try apply(document: document(unknown), dryRun: false, on: nil, program: "canvas", in: editor)
            expect(false, "an is: that names nothing")
        } catch {
            expectEqual(error.first.key, "note:a")
        }
        expectEqual(editor.file, before)
    },
    test("a type on a subboard's board and its note on the top board: the type is written first, wherever it is") {
        let editor = emptyEditor()
        let doc: JSON = ["drawing": "Boards", "nodes": [
            ["key": "card:kinds", "kind": "subboard", "props": ["title": "Kinds"], "place": ["at": [0, 0]]],
            ["key": "note:x", "kind": "sticky-note", "props": ["title": "X", "is": ["type:Thing"]], "place": ["at": [400, 0]]],
            ["key": "type:Thing", "in": "card:kinds", "kind": "sticky-note", "props": ["title": "Thing", "schema": ["type": "object"]], "place": ["at": [0, 0]]],
        ], "edges": []]
        let result = try apply(document: document(doc), dryRun: false, on: nil, program: "canvas", in: editor)
        guard let typeID = verdict(result, "type:Thing")?["id"]?.stringValue, let x = verdict(result, "note:x")?["id"]?.stringValue,
              let xID = UUID(uuidString: x).map(ShapeID.init), let cardID = verdict(result, "card:kinds")?["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(ShapeID.init) else {
            expect(false, "drawn: \(json(result).compactText)")
            return
        }
        expectEqual(editor.file.record(xID)?.propertiesJSON?["is"], .array([.string(typeID)]))
        expectEqual(editor.file.board(containing: UUID(uuidString: typeID).map(ShapeID.init)!), BoardID(owner: cardID))
    },
])

/// Contract 1, the app's interface: every attribute a plugin adds to a kind is in `canvas kinds` for that kind the day the plugin ships, so
/// `apply` and `draw` take it with no change to either. Each drawable kind's schema's added properties (each marked with its owner) that a
/// language may write (not read-only, not the plugin's own, not where it is, not what names it) are among the kind's attributes as
/// `canvas kinds` answers them.
@MainActor let kindsAttributesTests = Suite("every attribute a plugin adds is in canvas kinds", [
    test("each drawable kind's added properties are its attributes in canvas kinds") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let answer = try kinds(in: registry)
        let said = try JSON(encoding: answer).arrayValue ?? []
        var checked = 0
        for summary in said where summary["drawable"] == true {
            guard let word = summary["kind"]?.stringValue else { continue }
            let kind = ShapeKind(rawValue: word)
            let schema = KindSchema(registry.schema(for: kind) ?? JSONSchema([:]))
            let attributes = Set(summary["attributes"]?.objectValue?.keys.map { $0 } ?? [])
            for (name, property) in schema.properties where property["x-canvas-owner"] != nil {
                // What names a shape is the statement's own (`title:`, said as `names` by canvas kinds), not an attribute.
                guard !schema.isUnlisted(name), !schema.holdsPlace(name), property["readOnly"]?.boolValue != true,
                      !(name == LanguageKey.title.rawValue && summary["names"] == "named") else { continue }
                expect(attributes.contains(name), "\(word)'s \(name), added by \(property["x-canvas-owner"]?.stringValue ?? "?"), isn't in canvas kinds")
                checked += 1
            }
        }
        expect(checked > 10, "the shipped kinds have added properties to check (\(checked))")
    },
])

/// What `canvas query` answers, run as the app's server runs it.
@MainActor private func queried(_ text: String, in editor: CanvasEditor) throws -> JSON {
    try awaitResult { () async -> Result<JSON, RPCError> in
        do throws(RPCError) {
            return .success(try await editor.registry.runAutomationCommand("query", params: ["query": .string(text), "limit": 1000], editor: editor))
        } catch {
            return .failure(error)
        }
    }.get()
}

/// Reading a drawing (Drawings' words): `:drawn-by("NAME")`, its rows' `key` and `in`, what is gone in `absent`, and `:changed("NAME")` with how.
@MainActor let drawingQueriesTests = Suite("reading a drawing", [
    test("drawn-by finds the drawing's shapes with their keys and what holds them; absent lists what a person deleted; changed says how") {
        let editor = emptyEditor()
        let first = try apply(document: document(plan()), dryRun: false, on: nil, program: "canvas", in: editor)
        let ids = Dictionary(uniqueKeysWithValues: (json(first)["nodes"]?.arrayValue ?? []).compactMap { node -> (String, ShapeID)? in
            guard let key = node["key"]?.stringValue, let id = node["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(ShapeID.init) else { return nil }
            return (key, id)
        })
        let drawn = try queried(#":drawn-by("Plan")"#, in: editor)
        expectEqual(drawn["count"], 5, "four nodes and the arrow")
        let rows = drawn["rows"]?.arrayValue ?? []
        let byKey = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row["key"]?.stringValue.map { ($0, row) } })
        expectEqual(Set(byKey.keys), ["type:Task", "frame:sprint", "note:a", "note:b", "edge note:a -> note:b"])
        expectEqual(byKey["note:a"]?["in"], "frame:sprint", "the drawing's shape that holds it")
        expectEqual(byKey["note:b"]?["in"], nil)
        expectEqual(byKey["note:b"]?["at"], [[700, 0], [260, 200]])
        expectEqual(drawn["absent"], nil, "nothing is gone")
        expectEqual(try queried(#":changed("Plan")"#, in: editor)["count"], 0, "nothing changed since")

        guard let a = ids["note:a"], let b = ids["note:b"], let type = ids["type:Task"] else { return expect(false, "drawn") }
        editor.transact("Move") { $0.translate([b], by: CGPoint(x: 30, y: 0)) }
        editor.transact("Text") { $0.update(type) { record in
            var props = record.propertiesJSON ?? [:]
            props["text"] = "Something else"
            if let changed = try? editor.registry.shape(record, setting: ["text": props["text"]!]) { record = changed }
        } }
        editor.transact("Delete") { $0.delete([a]) }
        let changed = try queried(#":changed("Plan")"#, in: editor)
        let changes = Dictionary(uniqueKeysWithValues: (changed["rows"]?.arrayValue ?? []).compactMap { row in
            row["key"]?.stringValue.map { ($0, row["changed"]?.arrayValue?.compactMap(\.stringValue) ?? []) }
        })
        expectEqual(changes["note:b"], ["moved"])
        expectEqual(changes["type:Task"], ["text"])
        expectEqual(changes["frame:sprint"], nil, "what nobody changed")
        let gone = try queried(#":drawn-by("Plan")"#, in: editor)["absent"]?.arrayValue ?? []
        expectEqual(gone.compactMap { $0["key"]?.stringValue }.contains("note:a"), true)
        expectEqual(gone.first { $0["key"] == "note:a" }?["id"]?.stringValue, a.description)
        expectEqual(try queried(#":drawn-by("Other")"#, in: editor)["count"], 0, "another drawing's name finds nothing")
    },
    test("a shape two drawings hold is judged by each against what that one last wrote") {
        let editor = emptyEditor()
        _ = try apply(document: document(plan()), dryRun: false, on: nil, program: "canvas", in: editor)
        // a draw run moves the note and joins it to a drawing of its own, which so holds it where it is now
        _ = try draw(script: #"sticky-note "Ship it" right of origin (gap: 1200) below origin (gap: 0)"#, dryRun: false, reveal: false, program: "canvas",
                     drawing: "Other", in: editor)
        let byPlan = try queried(#":changed("Plan")"#, in: editor)
        expectEqual(byPlan["rows"]?.arrayValue?.compactMap { $0["key"]?.stringValue }, ["note:b"], "moved since Plan drew it: \(byPlan.compactText)")
        expectEqual(byPlan["rows"]?.arrayValue?.first?["changed"], ["moved"])
        expectEqual(try queried(#":changed("Other")"#, in: editor)["count"], 0, "as Other last wrote it")
        expectEqual(try queried(#":drawn-by("Other")"#, in: editor)["count"], 1, "Other holds it too")
    },
])

/// A drawing's own shape by the key its record keeps (a pill's `pill <edge key>`, an arrow's `edge <edge key>`).
@MainActor private func recorded(_ key: String, in drawing: String, of editor: CanvasEditor) -> ShapeID? {
    editor.file[DrawingsProperty.self].drawings[drawing]?.idsByKey[key]
}

/// A document of a frame holding a note, a card whose board holds another note, a third note on the top board, and the edges
/// between them, each pill where `pills` puts it (`at` from the frame's top-left, or the board's origin with no frame).
private func pills(far: (at: [Double], inFrame: Bool), near: (at: [Double], inFrame: Bool)?) -> JSON {
    func pill(_ place: (at: [Double], inFrame: Bool)) -> JSON {
        place.inFrame ? ["at": .array(place.at.map(JSON.number)), "in": "frame:f"] : ["at": .array(place.at.map(JSON.number))]
    }
    var edges: [JSON] = [["from": "note:a", "to": "note:far", "place": ["pill": pill(far)]]]
    edges.append(near.map { ["from": "note:a", "to": "note:c", "place": ["pill": pill($0)]] } ?? ["from": "note:a", "to": "note:c"])
    return ["drawing": "Pills", "nodes": [
        ["key": "card:far", "kind": "subboard", "props": ["title": "Far away"], "place": ["at": [0, 0]]],
        ["key": "note:far", "in": "card:far", "kind": "sticky-note", "props": ["title": "Far"], "place": ["at": [0, 0]]],
        ["key": "frame:f", "kind": "frame", "props": ["title": "Here"], "place": ["at": [400, 0], "size": [700, 400]]],
        ["key": "note:a", "in": "frame:f", "kind": "sticky-note", "props": ["title": "A"], "place": ["at": [40, 60]]],
        ["key": "note:c", "kind": "sticky-note", "props": ["title": "C"], "place": ["at": [1400, 0]]],
    ], "edges": .array(edges)]
}

/// What an arrow is bound to, on the top board.
@MainActor private func ends(of arrow: ShapeID?, in editor: CanvasEditor) -> Set<ShapeID> {
    guard let arrow, let record = editor.file.record(arrow) else { return [] }
    return Set(record.boundShapes(in: ShapeContext(document: editor.file[.root], registry: editor.registry)))
}

@MainActor let applyRedrawShippedTests = Suite("canvas apply, drawn again where the plan changed", [
    test("a pill an edge drew is put where the document says now: another place in its frame, then out of it, the same pill each time") {
        let editor = emptyEditor()
        _ = try apply(document: document(pills(far: ([300, 40], true), near: nil)), dryRun: false, on: nil, program: "canvas", in: editor)
        guard let pill = recorded("pill note:a -> note:far", in: "Pills", of: editor), let frame = recorded("frame:f", in: "Pills", of: editor) else {
            return expect(false, "the pill and the frame are the drawing's")
        }
        expectEqual(editor.file.record(pill)?.box?.origin, CGPoint(x: 700, y: 40), "made where the document says, from the frame's top-left")
        expectEqual(editor.file.record(pill)?.container, frame)
        let lower = try apply(document: document(pills(far: ([300, 140], true), near: nil)), dryRun: false, on: nil, program: "canvas", in: editor)
        expectEqual(json(lower)["edges"]?.arrayValue?.first?["did"], "updated", "the edge whose pill moved")
        expectEqual(recorded("pill note:a -> note:far", in: "Pills", of: editor), pill, "the same pill")
        expectEqual(editor.file.record(pill)?.box?.origin, CGPoint(x: 700, y: 140))
        expectEqual(editor.file.record(pill)?.container, frame)
        expectEqual(editor.undoHistory.undoName, "Draw")
        let out = try apply(document: document(pills(far: ([1200, 40], false), near: nil)), dryRun: false, on: nil, program: "canvas", in: editor)
        expectEqual(json(out)["edges"]?.arrayValue?.first?["did"], "updated")
        expectEqual(editor.file.record(pill)?.box?.origin, CGPoint(x: 1200, y: 40), "from the board's origin")
        expectEqual(editor.file.record(pill)?.container, nil, "out of the frame")
        let again = try apply(document: document(pills(far: ([1200, 40], false), near: nil)), dryRun: false, on: nil, program: "canvas", in: editor)
        expectEqual(json(again)["edges"]?.arrayValue?.first?["did"], "unchanged", "where it is already")
        editor.undo()
        expectEqual(editor.file.record(pill)?.box?.origin, CGPoint(x: 700, y: 140), "one undo puts it back")
    },
    test("an edge drawn straight that goes through a pill now is drawn anew through one, and back, the pill it no longer uses deleted") {
        let editor = emptyEditor()
        _ = try apply(document: document(pills(far: ([300, 40], true), near: nil)), dryRun: false, on: nil, program: "canvas", in: editor)
        guard let a = recorded("note:a", in: "Pills", of: editor), let c = recorded("note:c", in: "Pills", of: editor) else { return expect(false, "drawn") }
        let straight = recorded("edge note:a -> note:c", in: "Pills", of: editor)
        expectEqual(ends(of: straight, in: editor), [a, c], "straight")
        let through = try apply(document: document(pills(far: ([300, 40], true), near: ([300, 200], true))), dryRun: false, on: nil, program: "canvas", in: editor)
        expectEqual(json(through)["edges"]?.arrayValue?.last?["did"], "created", json(through).compactText)
        let arrow = recorded("edge note:a -> note:c", in: "Pills", of: editor)
        guard let pill = recorded("pill note:a -> note:c", in: "Pills", of: editor) else { return expect(false, "a pill: \(json(through).compactText)") }
        expectEqual(ends(of: arrow, in: editor), [a, pill], "through the pill")
        expectEqual(editor.file.record(pill)?.box?.origin, CGPoint(x: 700, y: 200))
        expectEqual(editor.file.record(straight ?? ShapeID()), nil, "the straight arrow is gone")
        _ = try apply(document: document(pills(far: ([300, 40], true), near: nil)), dryRun: false, on: nil, program: "canvas", in: editor)
        expectEqual(ends(of: recorded("edge note:a -> note:c", in: "Pills", of: editor), in: editor), [a, c], "straight again")
        expectEqual(editor.file.record(pill), nil, "and the pill it no longer goes through is deleted")
        expectEqual(recorded("pill note:a -> note:c", in: "Pills", of: editor), nil)
    },
    test("a node drawn anew on another board takes the arrow into the pill that stood for it: no pill is left standing for the shape that went") {
        let editor = emptyEditor()
        _ = try apply(document: document(pills(far: ([300, 40], true), near: nil)), dryRun: false, on: nil, program: "canvas", in: editor)
        guard let oldFar = recorded("note:far", in: "Pills", of: editor), let oldPill = recorded("pill note:a -> note:far", in: "Pills", of: editor) else {
            return expect(false, "drawn")
        }
        // the far note leaves the card's board for the top board, so it is another shape there
        var moved = pills(far: ([300, 40], true), near: nil)
        moved["nodes"] = .array((moved["nodes"]?.arrayValue ?? []).map { node in
            guard node["key"] == "note:far" else { return node }
            var node = node
            node["in"] = nil
            node["place"] = ["at": [1400, 400]]
            return node
        })
        let again = try apply(document: document(moved), dryRun: false, on: nil, program: "canvas", in: editor)
        guard let newFar = recorded("note:far", in: "Pills", of: editor) else { return expect(false, "drawn again: \(json(again).compactText)") }
        expect(newFar != oldFar, "another shape")
        expectEqual(editor.file.record(oldPill), nil, "the pill that stood for the shape that went is gone")
        let standingForGone = editor.file[.root].shapes.filter { $0.propertiesJSON?["target"]?["id"]?.stringValue == oldFar.description }
        expectEqual(standingForGone.count, 0, "and nothing stands for it")
        guard let arrow = recorded("edge note:a -> note:far", in: "Pills", of: editor), let a = recorded("note:a", in: "Pills", of: editor) else { return expect(false, "the edge") }
        expect(ends(of: arrow, in: editor).contains(a), "the edge drawn anew from A")
    },
    test("the drawing's shapes' issues are said once, as it ends, every time; an issue it brings to a shape that isn't the drawing's is said") {
        let editor = emptyEditor()
        _ = try draw(script: #"sticky-note "Ship it" right of origin (gap: 2000) below origin (gap: 0)"#, dryRun: false, reveal: false, program: "canvas", in: editor)
        let first = json(try apply(document: document(plan()), dryRun: false, on: nil, program: "canvas", in: editor))
        let warnings = first["warnings"]?.arrayValue ?? []
        func saying(_ list: [JSON], _ name: String) -> [JSON] { list.filter { $0["message"]?.stringValue?.hasPrefix(name + ": ") == true } }
        let own = saying(warnings, #""note:b""#)
        expectEqual(own.count, 1, "the note whose title another shape has, once, by its key: \(first["warnings"]?.compactText ?? "")")
        expectEqual(own.first?["key"], "note:b")
        let brought = saying(warnings, #""Ship it""#)
        expectEqual(brought.count, 1, "the person's note, which the drawing gave a twin, by its title: \(first["warnings"]?.compactText ?? "")")
        expectEqual(brought.first?["key"], "note:b", "on the node whose statement brought it")
        expect(warnings.allSatisfy { $0["severity"] != "incomplete" }, "nothing the drawing's own shapes still need")
        let again = json(try apply(document: document(plan()), dryRun: false, on: nil, program: "canvas", in: editor))
        let said = again["warnings"]?.arrayValue ?? []
        expectEqual(saying(said, #""note:b""#).count, 1, "said again, once, though nothing changed: \(again["warnings"]?.compactText ?? "")")
        expectEqual(saying(said, #""Ship it""#).count, 0, "nothing new brought to the person's note")
    },
    test("a run's warnings say only their line, message, severity and attribute") {
        let editor = emptyEditor()
        _ = try draw(script: #"sticky-note "Deploy""#, dryRun: false, reveal: false, program: "canvas", in: editor)
        let result = try draw(script: #"sticky-note "deploy" right of "Deploy""#, dryRun: false, reveal: false, program: "canvas", in: editor)
        let warnings = (try JSON(encoding: result))["warnings"]?.arrayValue ?? []
        expect(!warnings.isEmpty, "a near miss of a title is warned of")
        for warning in warnings {
            expect(Set(warning.objectValue?.keys.map { $0 } ?? []).isSubset(of: ["line", "message", "severity", "attribute"]), warning.compactText)
        }
    },
])

private func noteNode(_ key: String, _ title: String, at: [Double], in container: String? = nil, more: JSON = [:]) -> JSON {
    var props: JSON = ["title": .string(title)]
    for (name, value) in more.objectValue ?? [:] { props[name] = value }
    var node: JSON = ["key": .string(key), "kind": "sticky-note", "props": props, "place": ["at": .array(at.map(JSON.number))]]
    if let container { node["in"] = .string(container) }
    return node
}

@MainActor private func applied(_ doc: JSON, on editor: CanvasEditor, onBoard: String? = nil) throws -> JSON {
    json(try apply(document: document(doc), dryRun: false, on: onBoard, program: "canvas", in: editor))
}

/// What the review of the drawing-layers rewrite found, held: a document's deletes at every depth, a kind changed, edge keys, line
/// separators in a text, a pill for a private node refused, a plan that shares a pill otherwise, a redraw of a relationship type, and
/// a measure that knows the document's own types and the board it lands on.
@MainActor let applyReviewTests = Suite("canvas apply, as the review left it", [
    test("subboards gone two deep with a note on the inner board are deleted, whatever order their boards come in") {
        for round in 0..<6 {
            let editor = emptyEditor()
            _ = try applied(["drawing": "Deep", "nodes": [
                ["key": "s1", "kind": "subboard", "props": ["title": .string("Outer \(round)")], "place": ["at": [0, 0]]],
                ["key": "s2", "in": "s1", "kind": "subboard", "props": ["title": .string("Inner \(round)")], "place": ["at": [0, 0]]],
                noteNode("c2", "Deepest", at: [0, 0], in: "s2"),
                noteNode("keep", "Kept", at: [600, 0]),
            ], "edges": []], on: editor)
            expectEqual(editor.file.shapeCount, 4)
            let gone = try applied(["drawing": "Deep", "nodes": [noteNode("keep", "Kept", at: [600, 0])], "edges": []], on: editor)
            expectEqual(Set(gone["deleted"]?.arrayValue?.compactMap { $0["key"]?.stringValue } ?? []), ["s1", "s2", "c2"], "round \(round)")
            expectEqual(editor.file.shapeCount, 1, "round \(round): only the kept note")
        }
    },
    test("a node that changes kind is drawn anew and its old shape deleted, not left behind") {
        let editor = emptyEditor()
        let first = try applied(["drawing": "K", "nodes": [noteNode("n", "Thing", at: [0, 0])], "edges": []], on: editor)
        let old = try require(first["nodes"]?.arrayValue?.first?["id"]?.stringValue)
        let second = try applied(["drawing": "K", "nodes": [["key": "n", "kind": "frame", "props": ["title": "Thing"], "place": ["at": [0, 0], "size": [400, 300]]]], "edges": []], on: editor)
        expectEqual(second["nodes"]?.arrayValue?.first?["did"], "created")
        expectEqual(second["deleted"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, [old])
        expectEqual(editor.file.shapeCount, 1, "the frame alone")
    },
    test("two edges of one key are refused by place, and nothing is drawn") {
        let editor = emptyEditor()
        let doc: JSON = ["drawing": "E", "nodes": [noteNode("a", "A", at: [0, 0]), noteNode("b", "B", at: [400, 0]), noteNode("c", "C", at: [800, 0])],
                         "edges": [["from": "a", "to": "b", "key": "k"], ["from": "b", "to": "c", "key": "k"]]]
        do throws(DocumentError) {
            _ = try apply(document: document(doc), dryRun: false, on: nil, program: "canvas", in: editor)
            expect(false, "a key twice")
        } catch {
            expectEqual(error.first.edge, 1)
            expectEqual(error.reason, "duplicate")
        }
        expectEqual(editor.file.shapeCount, 0)
    },
    test("a text with a line or paragraph separator is one statement, and every node after it lands where it says") {
        let editor = emptyEditor()
        let answer = try applied(["drawing": "S", "nodes": [
            noteNode("a", "One\u{2028}line", at: [0, 0], more: ["text": "First\u{2029}second\u{85}third", "fieldValues": ["note": "x\u{2028}y"]]),
            noteNode("b", "Next", at: [500, 40]),
        ], "edges": []], on: editor)
        expectEqual(answer["nodes"]?.arrayValue?.map { $0["did"]?.stringValue }, ["created", "created"], answer.compactText)
        let b = try require(answer["nodes"]?.arrayValue?.last?["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(ShapeID.init))
        expectEqual(editor.file.record(b)?.box?.origin, CGPoint(x: 500, y: 40), "the next node where its place says")
    },
    test("a pill stands for its node as the node is: nothing is written to it, and it says unchanged; a private node is refused by its key, never made public, and nothing is drawn") {
        let editor = emptyEditor()
        _ = try applied(["drawing": "P", "nodes": [noteNode("a", "A", at: [0, 0]), noteNode("hub", "Hub", at: [900, 0])], "edges": []], on: editor)
        let second = try applied(["drawing": "P", "nodes": [noteNode("a", "A", at: [0, 0]), noteNode("hub", "Hub", at: [900, 0])],
                                  "edges": [["from": "a", "to": "hub", "place": ["pill": ["at": [300, 0]]]]]], on: editor)
        expectEqual(second["nodes"]?.arrayValue?.first { $0["key"] == "hub" }?["did"], "unchanged", "public as every shape is: \(second.compactText)")
        let before = editor.file
        let secret: JSON = ["drawing": "P", "nodes": [noteNode("a", "A", at: [0, 0]), noteNode("hub", "Hub", at: [900, 0]),
                                                      noteNode("secret", "Secret", at: [900, 400], more: ["private": true])],
                            "edges": [["from": "a", "to": "hub", "place": ["pill": ["at": [300, 0]]]],
                                      ["from": "a", "to": "secret", "place": ["pill": ["at": [300, 100]]]]]]
        do throws(DocumentError) {
            _ = try apply(document: document(secret), dryRun: false, on: nil, program: "canvas", in: editor)
            expect(false, "a pill for a private node")
        } catch {
            expectEqual(error.first.key, "secret")
            expectEqual(error.first.edge, 1)
            expectEqual(error.reason, "invalid_value")
            expect(error.first.message.contains("isn't public"), error.first.message)
            expect(error.first.hint?.contains("ask the user") == true, error.first.hint ?? "")
        }
        expect(editor.file == before, "nothing drawn, nothing made public")
    },
    test("a plan that gives a sharer a pill of its own draws one, and leaves the pill it shared where its maker's plan puts it") {
        let editor = emptyEditor()
        func doc(_ second: JSON) -> JSON {
            ["drawing": "Share", "nodes": [noteNode("c1", "C1", at: [0, 0]), noteNode("c2", "C2", at: [0, 400]), noteNode("x", "X", at: [1200, 200])],
             "edges": [["from": "c1", "to": "x", "place": ["pill": ["at": [400, 60]]]], ["from": "c2", "to": "x", "place": ["pill": second]]]]
        }
        _ = try applied(doc(["share": "c1"]), on: editor)
        let shared = try require(recorded("pill c1 -> x", in: "Share", of: editor))
        let second = try require(recorded("edge c2 -> x", in: "Share", of: editor))
        expectEqual(ends(of: second, in: editor).contains(shared), true, "C2's arrow goes into C1's pill")
        _ = try applied(doc(["at": [400, 460]]), on: editor)
        let own = try require(recorded("pill c2 -> x", in: "Share", of: editor))
        expect(own != shared, "a pill of its own")
        let arrow = try require(recorded("edge c2 -> x", in: "Share", of: editor))
        expectEqual(ends(of: arrow, in: editor).contains(own), true, "C2's arrow goes into it")
        expectEqual(editor.file.record(own)?.box?.origin, CGPoint(x: 400, y: 460))
        expectEqual(editor.file.record(shared)?.box?.origin, CGPoint(x: 400, y: 60), "C1's pill where C1's edge says")
    },
    test("a relationship type and its ends drawn again are unchanged, with no new step") {
        let editor = emptyEditor()
        let object: JSON = ["type": "object", "properties": ["role": ["type": "string"]]]
        let doc: JSON = ["drawing": "R", "nodes": [
            noteNode("type:Person", "Person", at: [0, 0], more: ["schema": ["type": "object"], "text": "A person"]),
            noteNode("rel:Job", "Job", at: [420, 60], more: ["relationship": true, "schema": object, "text": "A job: the role, and where it is held"]),
            noteNode("type:Company", "Company", at: [700, 0], more: ["schema": ["type": "object"], "text": "A company"]),
        ], "edges": [["from": "type:Person", "to": "rel:Job", "props": ["text": "jobs"]], ["from": "rel:Job", "to": "type:Company", "props": ["text": "staff"]]]]
        let first = try applied(doc, on: editor)
        let job = try require(first["nodes"]?.arrayValue?.first { $0["key"] == "rel:Job" }?["at"]?.arrayValue?.first?.arrayValue)
        expectEqual(job, [420, 60], "the pill's frame where the plan puts it: \(first.compactText)")
        let file = editor.file
        let again = try applied(doc, on: editor)
        expectEqual(again["nodes"]?.arrayValue?.map { $0["did"]?.stringValue }, ["unchanged", "unchanged", "unchanged"], again.compactText)
        expectEqual(editor.file, file, "nothing written")
    },
    test("a measure reads a node's type chips as the document's own types, and says a pill's width from the board it lands on") {
        let editor = emptyEditor()
        // a board whose name is longer than the pill's, so where the pill says its shape is decides its width
        _ = try draw(script: #"subboard "Home, where every drawing of ours goes" right of origin (gap: 0) below origin (gap: 0)"#, dryRun: false, reveal: false,
                     program: "canvas", in: editor)
        let doc: JSON = ["drawing": "M", "nodes": [
            noteNode("type:Long", "A rather long workflow handler", at: [0, -300], more: ["schema": ["type": "object"]]),
            ["key": "frame:f", "kind": "frame", "props": ["title": "F", "is": ["type:Long"]], "place": ["at": [0, 0], "size": [600, 400]]],
            noteNode("top", "Top note", at: [700, 0]),
            ["key": "card:d", "kind": "subboard", "props": ["title": "Deeper"], "place": ["at": [700, 400]]],
            noteNode("inner", "Inner note", at: [0, 0], in: "card:d"),
        ], "edges": [["from": "inner", "to": "top", "place": ["pill": ["at": [300, 0]]]]]]
        let home = "Home, where every drawing of ours goes"
        let measured = try JSON(encoding: try measure(document: document(doc), on: home, program: "canvas", in: editor.registry, namesBeyond: editor))
        let unseated = try JSON(encoding: try measure(document: document(doc), program: "canvas", in: editor.registry, namesBeyond: editor))
        _ = try applied(doc, on: editor, onBoard: home)
        guard let frame = recorded("frame:f", in: "M", of: editor), let record = editor.file.record(frame) else { return expect(false, "the frame drawn") }
        expectEqual(measured["nodes"]?["frame:f"]?["titleWidth"]?.numberValue, Double(editor.adornmentLeastWidth(of: record)),
                    "the chip of the document's own type, as wide as it's drawn")
        guard let pill = recorded("pill inner -> top", in: "M", of: editor), let drawn = editor.file.record(pill)?.box else { return expect(false, "the pill drawn") }
        let pills = measured["pills"]?.arrayValue ?? []
        let sized = pills.first { $0["for"] == "top" && $0["from"] == "card:d" }?["size"]?.arrayValue?.compactMap(\.numberValue)
        expectEqual(sized, [Double(drawn.width), Double(drawn.height)], "measured from Home's board, as drawn: \(measured["pills"]?.compactText ?? "")")
        let fromRoot = (unseated["pills"]?.arrayValue ?? []).first { $0["for"] == "top" && $0["from"] == "card:d" }?["size"]?.arrayValue?.compactMap(\.numberValue)
        expect(fromRoot != sized, "measured from the root, the place it says is another, and so is its width: \(fromRoot ?? []) and \(sized ?? [])")
    },
])
