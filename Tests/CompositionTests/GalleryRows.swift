import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import Locking
import Mentions
import Selection
import StickyNotes
import TestKit
import Titles
import Types

// The gallery's states for rows on a type's note (slice 9): what the spot says while the model writes the
// schema and when it fails, the rows of the shared types as the plan's boards draw them (board 5 panels 1 and 7
// above all), the fold, the chips, the rows locked, edited, zoomed out and many. Slice 11's states, on a note that
// is one, are `valueStates`. Named for the board panel each answers: Main, Flow1, Flow5.

private let tall = CGSize(width: 780, height: 560)
private let wideStage = CGSize(width: 900, height: 560)

/// A fixed id for the nth type of a state, so a type's color is the same in every run (`TypeColors`).
func rowsTypeID(_ n: Int) -> ShapeID {
    ShapeID(UUID(uuidString: String(format: "0E5B1B%02X-0000-4000-8000-0000000000%02X", n, n))!)
}

/// A type's JSON Schema of text fields, `date` ones where the names say so.
func fieldsSchema(_ names: [String], required: [String] = []) -> String {
    let properties = names.map { name in
        name.lowercased().contains("date") || name == "birthday" ? #""\#(name)": {"type": "string", "format": "date"}"# : #""\#(name)": {"type": "string"}"#
    }.joined(separator: ", ")
    let needed = required.isEmpty ? "" : #", "required": [\#(required.map { "\"\($0)\"" }.joined(separator: ", "))]"#
    return #"{"type": "object", "properties": {\#(properties)}\#(needed)}"#
}

let personThree: FieldFixtures.TypeText = (FieldFixtures.personID, "Person", "A person has a name, an email and a birthday. It must have a name.",
                                                  fieldsSchema(["name", "email", "birthday"], required: ["name"]))
let employeeThree: FieldFixtures.TypeText = (FieldFixtures.employeeID, "Employee", "An employee is a person with a role, a start date and a team.",
                                                    fieldsSchema(["role", "startDate", "team"]))

extension CanvasEditor {
    /// A type note of the fixed texts, at `origin`, as wide and tall as the plan's boards draw it (laid out, it is as wide
    /// as its rows read at, and as tall as its words and rows).
    @discardableResult
    func put(_ type: FieldFixtures.TypeText, at origin: CGPoint = CGPoint(x: 40, y: 40), words: String? = nil) -> ShapeID {
        addTypeNote(type.schema, text: MentionText(plain: words ?? type.words), title: type.title,
                    frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), id: type.id)
    }

    /// A note saying `text`, 200 x 200 at `origin`.
    @discardableResult
    func rowsNote(_ text: String, at origin: CGPoint) -> ShapeID {
        add(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: text)))
    }
}

/// The whole canvas at its origin.
@MainActor
func canvas(_ stage: GalleryStage, zoom: CGFloat = 1) -> GalleryOutput { .image(stage.render(at: .zero, zoom: zoom)) }

/// The note made a type, and its read begun (the scheduler's next turn), with the call held out.
@MainActor
private func beginRead(_ stage: GalleryStage, _ id: ShapeID) {
    stage.editor.makeType(id)
    stage.spin(0.05)
}

/// Waits for the sync to be done with a shape: no call out and no edit waiting.
@MainActor
private func settle(_ stage: GalleryStage, _ id: ShapeID) {
    spinRunLoop(until: {
        guard let sync = stage.editor.typeSync else { return true }
        if case .updating = sync.status(of: id) { return false }
        return !sync.isWaiting(id)
    })
    stage.spin(0.05)
}

/// The nine fields of `text`, as the shared `wide` type writes them, titled and given a color of its own.
func wideType(_ count: Int, id: ShapeID, title: String, words: String) -> FieldFixtures.TypeText {
    (id, title, words, FieldFixtures.wide(count).schema)
}

@MainActor
let rowStates: [GalleryState] = [
    // What the spot says while the model writes the schema
    GalleryState("Flow1-p2-reading", answers: "Flow1 p2", "the note made a type, the call out: its words, then three gray bars where the rows will be", size: CGSize(width: 440, height: 340)) { stage in
        stage.model.holdsAnswers = true
        stage.model.queue(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#)
        let id = stage.editor.rowsNote("A pet in my household", at: CGPoint(x: 100, y: 70))
        beginRead(stage, id)
        spinRunLoop(until: { stage.model.waiting == 1 })
        stage.editor.selection = nil
        let out = canvas(stage)
        stage.model.release()
        return out
    },
    GalleryState("Flow1-p3-rows", answers: "Flow1 p3", "the schema landed: Person's rows, `name Text`, `email Text`, `birthday Date`, the name needed", size: CGSize(width: 440, height: 340)) { stage in
        stage.editor.put(personThree, at: CGPoint(x: 80, y: 60))
        return canvas(stage)
    },
    GalleryState("Flow1-p2-failed", answers: "Flow1 p2", "the read failed: the reason in gray and `Retry` in the accent blue", size: CGSize(width: 440, height: 340)) { stage in
        stage.model.queue(.overloaded)
        let id = stage.editor.rowsNote("A pet in my household", at: CGPoint(x: 100, y: 70))
        beginRead(stage, id)
        settle(stage, id)
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("Flow1-p2-no-key", answers: "Flow1 p2", "no API key: `No API key` and `Settings…`", size: CGSize(width: 440, height: 340)) { stage in
        stage.model.queue(.noKey)
        let id = stage.editor.rowsNote("A pet in my household", at: CGPoint(x: 100, y: 70))
        beginRead(stage, id)
        settle(stage, id)
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("Flow1-p2-too-long", answers: "Flow1 p2", "a schema too long for the model to write: the reason, with no button", size: CGSize(width: 440, height: 340)) { stage in
        let long = #"{"type": "object", "description": ""# + String(repeating: "x", count: 40_000) + #""}"#
        let id = stage.editor.addTypeNote(long, text: "A very long type", title: "Long", frame: CGRect(x: 100, y: 70, width: 200, height: 200))
        stage.editor.transact { $0.update(id, as: StickyNote.self) { $0.props.text = MentionText(plain: "A very long type, edited") } }
        stage.editor.typeSync?.commit(id)
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("rows-no-fields", "the model found no fields: `No fields`, gray, one row", size: CGSize(width: 440, height: 340)) { stage in
        stage.editor.addTypeNote(#"{"type": "object"}"#, text: "A thing nobody has described yet.", title: "Thing", frame: CGRect(x: 100, y: 70, width: 200, height: 200))
        return canvas(stage)
    },
    GalleryState("rows-blank-type", answers: "Flow2 p4", "a type with no words: a blank white note, 200 wide, no hairline", size: CGSize(width: 440, height: 340)) { stage in
        stage.editor.addTypeNote(TypeSchemaProperty.starter, text: "", title: "Company", frame: CGRect(x: 100, y: 70, width: 200, height: 200))
        return canvas(stage)
    },
    GalleryState("rows-read-again", "its words edited and the call out: the rows stay, no bars", size: CGSize(width: 440, height: 340)) { stage in
        let id = stage.editor.put(personThree, at: CGPoint(x: 80, y: 60))
        stage.model.holdsAnswers = true
        stage.model.queue(personThree.schema)
        stage.editor.transact { $0.update(id, as: StickyNote.self) { $0.props.text = MentionText(plain: "A person has a name, an email and a birthday. They may have a phone.") } }
        stage.editor.typeSync?.commit(id)
        spinRunLoop(until: { stage.model.waiting == 1 })
        let out = canvas(stage)
        stage.model.release()
        return out
    },

    // The rows
    GalleryState("Main-p7-inherited", answers: "Main 7, Flow4 p1", "Employee builds on Person: Person's three rows faint and ticked in blue, then Employee's three at full strength", size: wideStage) { stage in
        stage.editor.put(personThree, at: CGPoint(x: 460, y: 40))
        let employee = stage.editor.put(employeeThree, at: CGPoint(x: 40, y: 40))
        stage.editor.addTypeLink(FieldFixtures.personID, to: employee)
        return canvas(stage)
    },
    GalleryState("Flow5-p1-order", answers: "Flow5 p1", "the Order type: customer `→ Person`, shipping address with the Address chip and `›`, line items `List ›`, status `Choice`, tags `List of Text`, gift `Yes or no`, gift note `Text`; the needed ones dotted", size: tall) { stage in
        stage.editor.put(FieldFixtures.order, at: CGPoint(x: 40, y: 30))
        stage.editor.put(FieldFixtures.person, at: CGPoint(x: 400, y: 30))
        stage.editor.put(FieldFixtures.address, at: CGPoint(x: 400, y: 260))
        return canvas(stage)
    },
    GalleryState("Flow5-p7-kinds-a", answers: "Flow5 p7", "KindsA: text, number, date, yes or no, choice, choices, list of text, a group `2 fields ›`, another type's fields `[Address] ›`: every cell of the plan's `On the type` column", size: tall) { stage in
        stage.editor.put(FieldFixtures.everyKind.a, at: CGPoint(x: 40, y: 30))
        stage.editor.put(FieldFixtures.address, at: CGPoint(x: 400, y: 30))
        return canvas(stage)
    },
    GalleryState("Flow5-p7-kinds-b", answers: "Flow5 p7", "KindsB: a link to a Person, links, a list of groups, a list of Address's fields, either of two plain kinds, pairs, what no control suits, either with a group in it, an integer", size: tall) { stage in
        stage.editor.put(FieldFixtures.everyKind.b, at: CGPoint(x: 40, y: 30))
        stage.editor.put(FieldFixtures.person, at: CGPoint(x: 400, y: 30))
        stage.editor.put(FieldFixtures.address, at: CGPoint(x: 400, y: 260))
        return canvas(stage)
    },

    // The fold
    GalleryState("rows-fold-more", answers: "Flow5 p7", "twenty fields: eight rows and `+12 more ›` from the left edge", size: CGSize(width: 440, height: 440)) { stage in
        stage.editor.put(wideType(20, id: rowsTypeID(1), title: "Wide", words: "A type of twenty text fields."), at: CGPoint(x: 60, y: 30))
        return canvas(stage)
    },
    GalleryState("rows-fold-nine", "nine fields: every row shows, no fold", size: CGSize(width: 440, height: 440)) { stage in
        stage.editor.put(wideType(9, id: rowsTypeID(2), title: "Nine", words: "A type of nine text fields."), at: CGPoint(x: 60, y: 30))
        return canvas(stage)
    },
    GalleryState("rows-fold-inherited", "ten fields, four of them Person's: `from Person` and `4 fields ›` in place of the four, then six rows of its own", size: wideStage) { stage in
        let parent: FieldFixtures.TypeText = (FieldFixtures.personID, "Person", "A person has a name, an email, a phone and a birthday.", fieldsSchema(["name", "email", "phone", "birthday"]))
        let child: FieldFixtures.TypeText = (FieldFixtures.employeeID, "Employee", "An employee has a role, a start date, a manager, a team, a desk and a badge.",
                                             fieldsSchema(["role", "startDate", "manager", "team", "desk", "badge"]))
        stage.editor.put(parent, at: CGPoint(x: 460, y: 40))
        let employee = stage.editor.put(child, at: CGPoint(x: 40, y: 40))
        stage.editor.addTypeLink(FieldFixtures.personID, to: employee)
        return canvas(stage)
    },
    GalleryState("rows-gone-type", "Address deleted: the shipping address row holds its dashed chip with the last name (Person is still there: its chip is whole)", size: tall) { stage in
        stage.editor.put(FieldFixtures.person, at: CGPoint(x: 400, y: 30))
        stage.editor.put(FieldFixtures.address, at: CGPoint(x: 400, y: 300))
        stage.editor.put(FieldFixtures.order, at: CGPoint(x: 40, y: 30))
        stage.editor.transact("Delete") { $0.delete([FieldFixtures.addressID]) }
        return canvas(stage)
    },
    GalleryState("rows-long-name", "a name longer than 45% of the rows is cut with an ellipsis and its kind is whole", size: CGSize(width: 440, height: 340)) { stage in
        let long: FieldFixtures.TypeText = (rowsTypeID(3), "Long", "A type with a long field name.",
                                            fieldsSchema(["averyveryverylongfieldnamethatneverseemstoend", "short"], required: ["short"]))
        stage.editor.put(long, at: CGPoint(x: 60, y: 60))
        return canvas(stage)
    },
    GalleryState("rows-options", "a click on `Choice`: the menu it pops, the options in the schema's order, every item dimmed (outline)", isText: true) { stage in
        let order = stage.editor.put(FieldFixtures.order, at: CGPoint(x: 40, y: 30))
        _ = stage.render(at: .zero)
        let row = try require(stage.editor.rowBook?.rows(of: order).first { $0.name == "status" }, "the status row")
        let point = stage.viewPoint(CGPoint(x: row.valueRect.midX, y: row.rect.midY))
        stage.press(at: point)
        stage.release(at: point)
        let menu = try require(stage.editor.menuToPopUp, "a menu")
        return .text(menu.menu.outline.joined(separator: "\n") + "\n")
    },

    // Edited, locked, zoomed out, many
    GalleryState("rows-editing", answers: "Flow1 p1 to p2", "the type's words being edited: the rows stay under the editor, and the hairline", size: CGSize(width: 440, height: 340)) { stage in
        let id = stage.editor.put(personThree, at: CGPoint(x: 80, y: 60))
        _ = try stage.edit(id)
        return canvas(stage)
    },
    GalleryState("rows-locked", "a locked type: the same rows", size: CGSize(width: 440, height: 340)) { stage in
        let id = stage.editor.put(personThree, at: CGPoint(x: 80, y: 60))
        stage.editor.lock([id])
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("rows-zoomed-out", "six types at 30%: a bar for each row's name, a fold's three dots; the title large on the paper", size: CGSize(width: 560, height: 360)) { stage in
        let types: [FieldFixtures.TypeText] = [personThree, FieldFixtures.address, FieldFixtures.order, FieldFixtures.everyKind.a,
                                               wideType(20, id: rowsTypeID(4), title: "Wide", words: "Twenty fields."), employeeThree]
        for (place, type) in types.enumerated() {
            stage.editor.put(type, at: CGPoint(x: 40 + CGFloat(place % 3) * 380, y: 40 + CGFloat(place / 3) * 380))
        }
        stage.editor.addTypeLink(FieldFixtures.personID, to: FieldFixtures.employeeID)
        return canvas(stage, zoom: 0.3)
    },
    GalleryState("rows-many", "twelve types at 60%: every type shows its rows at once", size: CGSize(width: 900, height: 780)) { stage in
        let words = ["Pets", "Rooms", "Cars", "Trips", "Books", "Teams", "Tasks", "Meals", "Gifts", "Plans", "Tools", "Notes"]
        for (place, name) in words.enumerated() {
            let fields = Array(["name", "email", "phone", "birthday", "street", "city", "postcode", "notes"].prefix(2 + place % 5))
            let type: FieldFixtures.TypeText = (rowsTypeID(10 + place), name, "\(name) have \(fields.count) fields.", fieldsSchema(fields, required: ["name"]))
            stage.editor.put(type, at: CGPoint(x: 30 + CGFloat(place % 4) * 340, y: 30 + CGFloat(place / 4) * 330))
        }
        return canvas(stage, zoom: 0.6)
    },

    // A read that failed under a type's rows: the rows are the last good ones, and the note says why at their foot
    GalleryState("rows-read-failed", "its words edited and the read failed: the rows stay, and under them, one row more, the reason in gray and `Retry` in the accent blue", size: CGSize(width: 440, height: 340)) { stage in
        let id = stage.editor.put(personThree, at: CGPoint(x: 80, y: 60))
        failRead(stage, id, .overloaded)
        return canvas(stage)
    },
    GalleryState("rows-read-no-key", "its words edited with no API key: the rows stay, and under them `No API key` and `Settings…`", size: CGSize(width: 440, height: 340)) { stage in
        let id = stage.editor.put(personThree, at: CGPoint(x: 80, y: 60))
        failRead(stage, id, .noKey)
        return canvas(stage)
    },
    GalleryState("rows-read-too-long", "a sixty-field type too long for the model to write, its words edited: eight rows, `+52 more ›`, then `Schema too long to rewrite`, with no button", size: CGSize(width: 440, height: 440)) { stage in
        let fields = (1...60).map { #""field\#($0)": {"type": "string", "description": "\#(String(repeating: "x", count: 600))"}"# }
        let long = #"{"type": "object", "properties": {"# + fields.joined(separator: ", ") + "}}"
        let id = stage.editor.addTypeNote(long, text: "A very long type of sixty fields.", title: "Long", frame: CGRect(x: 60, y: 30, width: 200, height: 200), id: rowsTypeID(5))
        stage.editor.transact { $0.update(id, as: StickyNote.self) { $0.props.text = MentionText(plain: "A very long type of sixty fields, edited.") } }
        stage.editor.typeSync?.commit(id)
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("rows-read-failed-zoomed-out", "the failed read at 30%, beside the same type read: one bar more under its rows' bars", size: CGSize(width: 440, height: 240)) { stage in
        let id = stage.editor.put(personThree, at: CGPoint(x: 40, y: 40))
        let other: FieldFixtures.TypeText = (rowsTypeID(6), "Guest", personThree.words, personThree.schema)
        stage.editor.put(other, at: CGPoint(x: 440, y: 40))
        failRead(stage, id, .overloaded)
        return canvas(stage, zoom: 0.3)
    },
]

/// The type's words edited and read, the model failing with `error`.
@MainActor
private func failRead(_ stage: GalleryStage, _ id: ShapeID, _ error: LanguageModelError) {
    stage.model.queue(error)
    stage.editor.transact { $0.update(id, as: StickyNote.self) { $0.props.text = MentionText(plain: "A person has a name, an email and a birthday. They may have a phone.") } }
    stage.editor.typeSync?.commit(id)
    settle(stage, id)
    stage.editor.selection = nil
}
