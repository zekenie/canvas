import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Foundation
import Locking
import Mentions
import Selection
import StickyNotes
import TestKit
import Titles
import Types

// The gallery's states for the types cut: slices 3 to 5 (one `/is-a`, the look, New type), named for the
// panel of the plan's boards each answers (Main, Flow1, Flow2, Flow4). `galleryTests` is the suite;
// the harness is GalleryKit.swift.

private let personSchema = #"{"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}}}"#
private let employeeSchema = #"{"type": "object", "properties": {"name": {"type": "string"}, "role": {"type": "string"}, "startDate": {"type": "string"}}}"#
private let speakerSchema = #"{"type": "object", "properties": {"talk": {"type": "string"}}}"#
private let bareSchema = #"{"type": "object"}"#
private let personWords = "A person has a name and an email."
private let employeeWords = "An employee has a name, a role and a start date."
private let speakerWords = "A speaker has a talk."

private let wide = CGSize(width: 640, height: 360)
private let tall = CGSize(width: 640, height: 480)
private let small = CGSize(width: 440, height: 340)

/// A type's id, fixed, so its color is the same in every run (a type's color is its id's: `TypeColors`): the
/// first of the eight for Person, the second for Employee, and so on; other names by their letters.
private func galleryTypeID(_ title: String?) -> ShapeID {
    let colors = ["Person", "Employee", "Speaker", "Company", "Contractor", "Manager", "Visitor", "Broken"]
    let letters = (title ?? "").utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
    let color = colors.firstIndex(of: title ?? "") ?? letters % 8
    // The first eight bytes, summed with their position, modulo eight, are the index: byte 0 is what it takes.
    let first = (color + 4) % 8
    return ShapeID(UUID(uuidString: String(format: "%02X000000-0000-4000-8000-0000000%05X", first, letters))!)
}

private extension CanvasEditor {
    /// A note saying `text`, 200 x 200 at `origin`, titled `title` if given.
    @discardableResult
    func note(_ text: String, title: String? = nil, at origin: CGPoint, width: CGFloat = 200, height: CGFloat = 200) -> ShapeID {
        let props = StickyNote(frame: CGRect(origin: origin, size: CGSize(width: width, height: height)), text: MentionText(plain: text))
        return title.map { add(props, title: $0) } ?? add(props)
    }

    func typeNote(_ title: String?, schema: String, words: String = "", at origin: CGPoint, width: CGFloat = 200, height: CGFloat = 200) -> ShapeID {
        addTypeNote(schema, text: MentionText(plain: words), title: title, frame: CGRect(origin: origin, size: CGSize(width: width, height: height)),
                    id: galleryTypeID(title))
    }

    /// The chip on `id` titled `text`, in world units.
    func chip(_ text: String, on id: ShapeID) throws -> CGRect {
        try require(adornmentFrames(of: id).first { $0.adornment == .of(TypeChips.self) && $0.label.text == text }, "a chip \(text)").rect
    }
}

/// Person, Employee and Speaker as the boards draw them, down the right of a stage.
@MainActor
private func someTypes(_ stage: GalleryStage, from x: CGFloat = 300, y: CGFloat = 70, width: CGFloat = 130) -> (person: ShapeID, employee: ShapeID, speaker: ShapeID) {
    let editor = stage.editor
    let person = editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: x, y: y), width: width, height: 160)
    let employee = editor.typeNote("Employee", schema: employeeSchema, words: employeeWords, at: CGPoint(x: x + width + 12, y: y), width: width, height: 160)
    let speaker = editor.typeNote("Speaker", schema: speakerSchema, words: speakerWords, at: CGPoint(x: x + (width + 12) * 2, y: y), width: width, height: 160)
    return (person, employee, speaker)
}

/// A list picture: Ann's note, edited, `/is-a ` and then `typed` on its last line, the list under it.
@MainActor
private func listing(_ typed: String, in stage: GalleryStage, types: Bool = true) throws -> GalleryOutput {
    let ann = stage.editor.note("Ann Lee, staff engineer", title: "Ann", at: CGPoint(x: 40, y: 60))
    if types { _ = someTypes(stage, from: 280, y: 60, width: 110) }
    let view = try stage.edit(ann)
    stage.typeLine("/is-a " + typed)
    stage.window.settle()
    return .image(try stage.pictureWithList(of: view))
}

/// The whole canvas at its origin.
@MainActor
private func board(_ stage: GalleryStage, zoom: CGFloat = 1) -> GalleryOutput { .image(stage.render(at: .zero, zoom: zoom)) }

@MainActor
private let galleryTypesLookStates: [GalleryState] = [
    // Main
    GalleryState("Main-p1-type-note", answers: "Main 1", "a type's note: white paper, its pill `{} Person` solid in blue, its words with the highlights", size: small) { stage in
        _ = stage.editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: 80, y: 70), width: 280, height: 200)
        return board(stage)
    },
    GalleryState("Main-p4-instance-chip", answers: "Main 4", "an instance of Person: the light blue `Person` chip above its note", size: small) { stage in
        let person = stage.editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: 240, y: 70), width: 160, height: 180)
        let ann = stage.editor.note("Ann Lee", title: "Ann", at: CGPoint(x: 30, y: 70))
        stage.editor.addTypeLink(person, to: ann)
        return board(stage)
    },
    GalleryState("Main-p6-type-building-on-a-type", answers: "Main 6", "a type that builds on another: its `{} Employee` pill and the light `Person` chip", size: wide) { stage in
        let person = stage.editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: 380, y: 70), width: 220, height: 180)
        let employee = stage.editor.typeNote("Employee", schema: employeeSchema, words: employeeWords, at: CGPoint(x: 100, y: 70), width: 240, height: 180)
        stage.editor.addTypeLink(person, to: employee)
        return board(stage)
    },
    GalleryState("Main-p8-employee-chip", answers: "Main 8", "a note that is an Employee: the chip is the type's own color", size: small) { stage in
        let employee = stage.editor.typeNote("Employee", schema: employeeSchema, words: employeeWords, at: CGPoint(x: 240, y: 70), width: 160, height: 180)
        let bo = stage.editor.note("Bo Chen", title: "Bo", at: CGPoint(x: 30, y: 70))
        stage.editor.addTypeLink(employee, to: bo)
        return board(stage)
    },

    // Flow1
    GalleryState("Flow1-p1-list-type", answers: "Flow1 p1", "`/is-a type` on a note's last line, the list one highlighted `Type` row (gray chip)", size: small) { stage in
        try listing("type", in: stage, types: false)
    },
    GalleryState("Flow1-p2-untitled-type", answers: "Flow1 p2", "the note made a type, untitled: white, a gray `{} Untitled` pill", size: small) { stage in
        let id = stage.editor.note("A pet in my household", at: CGPoint(x: 100, y: 70))
        stage.editor.makeType(id)
        stage.editor.selection = nil
        return board(stage)
    },
    GalleryState("Flow1-p3-named-type", answers: "Flow1 p3", "the type named: its pill solid in its color", size: small) { stage in
        let id = stage.editor.note("A pet in my household", at: CGPoint(x: 100, y: 70))
        stage.editor.makeType(id)
        stage.editor.transact { $0.update(id) { $0[TitleProperty.self] = "Pet" } }
        stage.editor.selection = nil
        return board(stage)
    },

    // Flow2
    GalleryState("Flow2-p1-list-types", answers: "Flow2 p1", "`/is-a ` with nothing typed: `Type`, a line, then the file's types by name, the first type highlighted", size: tall) { stage in
        try listing("", in: stage)
    },
    GalleryState("Flow2-p1-list-narrowed", answers: "Flow2 p1", "`/is-a pe`: the types that match, the best highlighted, matched letters semibold, then `New type “Pe”` last", size: tall) { stage in
        try listing("pe", in: stage)
    },
    GalleryState("Flow2-p2-instance-chip", answers: "Flow2 p2", "after Person is picked: the line gone, the light `Person` chip above the note", size: wide) { stage in
        let ann = stage.editor.note("Ann Lee, staff engineer", title: "Ann", at: CGPoint(x: 40, y: 70))
        _ = someTypes(stage, from: 280, y: 70, width: 110)
        _ = try stage.edit(ann)
        stage.typeLine("/is-a person")
        stage.window.pressReturn()
        stage.window.settle()
        stage.window.pressEscape()
        stage.editor.selection = nil
        return board(stage)
    },
    GalleryState("Flow2-p3-selected-notes", answers: "Flow2 p3", "three notes selected, ready for Is a ▸ in their menu", size: wide) { stage in
        let ids = (0..<3).map { stage.editor.note("Note \($0 + 1)", at: CGPoint(x: 30 + CGFloat($0) * 210, y: 70), width: 190, height: 160) }
        stage.editor.selectedShapeIDs = ids
        return board(stage)
    },
    GalleryState("Flow2-p3-menu", answers: "Flow2 p3", "the menu of three selected notes: Lock and Is a ▸ with no line between, Is a's items (outline)", size: wide, isText: true) { stage in
        _ = someTypes(stage, from: 30, y: 250, width: 110)
        let ids = (0..<3).map { stage.editor.note("Note \($0 + 1)", at: CGPoint(x: 30 + CGFloat($0) * 210, y: 40), width: 190, height: 160) }
        stage.editor.selectedShapeIDs = ids
        let outline = stage.menuOutline(at: CGPoint(x: 120, y: 110))
        return .text(outline.joined(separator: "\n") + "\n")
    },
    GalleryState("Flow2-p4-list-new-type", answers: "Flow2 p4", "`/is-a company`, nothing matching: the one row `New type “Company”`, highlighted, no chip", size: tall) { stage in
        try listing("company", in: stage)
    },
    GalleryState("Flow2-p4-list-match-and-new-type", answers: "Flow2 p4", "`/is-a co` with a Company type in the file: `Company` highlighted, then `New type “Co”` last, no chip", size: tall) { stage in
        _ = stage.editor.typeNote("Company", schema: bareSchema, at: CGPoint(x: 280, y: 60), width: 110, height: 160)
        return try listing("co", in: stage, types: false)
    },
    GalleryState("Flow2-p4-after-new-type", answers: "Flow2 p4", "after the pick: the new Company note beside Ann, white with its pill, in editing; Ann has the light `Company` chip", size: wide) { stage in
        let ann = stage.editor.note("Ann Lee, staff engineer", title: "Ann", at: CGPoint(x: 40, y: 70))
        _ = stage.editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: 40, y: 300), width: 150, height: 40)
        _ = try stage.edit(ann)
        stage.typeLine("/is-a company")
        stage.window.pressReturn()
        stage.window.settle()
        return board(stage)
    },

    // Flow4
    GalleryState("Flow4-p1-employee-is-a-person", answers: "Flow4 p1", "Employee is a Person: its `{} Employee` pill and the light `Person` chip", size: wide) { stage in
        let person = stage.editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: 380, y: 70), width: 220, height: 180)
        let employee = stage.editor.typeNote("Employee", schema: employeeSchema, words: employeeWords, at: CGPoint(x: 100, y: 70), width: 240, height: 180)
        stage.editor.addTypeLink(person, to: employee)
        return board(stage)
    },
    GalleryState("Flow4-p2-two-chips", answers: "Flow4 p2", "a note that is two types: an `Employee` chip and a `Speaker` chip, two colors", size: wide) { stage in
        let types = someTypes(stage, from: 300, y: 70, width: 100)
        let ann = stage.editor.note("Ann Lee", title: "Ann", at: CGPoint(x: 40, y: 70), width: 220)
        stage.editor.addTypeLink(types.employee, to: ann)
        stage.editor.addTypeLink(types.speaker, to: ann)
        return board(stage)
    },
    GalleryState("Flow4-p4-deleted-type", answers: "Flow4 p4", "its type deleted: the chip dashed, italic and gray, with the last name", size: small) { stage in
        let gone = stage.editor.typeNote("Visitor", schema: bareSchema, at: CGPoint(x: 240, y: 70), width: 150, height: 100)
        let guest = stage.editor.note("Its type was deleted", title: "Guest", at: CGPoint(x: 30, y: 70))
        stage.editor.addTypeLink(gone, to: guest)
        stage.editor.transact("Delete") { $0.delete([gone]) }
        return board(stage)
    },

    // States no board draws
    GalleryState("list-no-matches", "text over a title's limit offers no new type: one quiet `No matches` row") { stage in
        try listing(String(repeating: "x", count: 81), in: stage)
    },
    GalleryState("list-none", "a type in a file with no other type it may be: one quiet `None` row") { stage in
        let id = stage.editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: 40, y: 60))
        let view = try stage.edit(id)
        stage.typeLine("/is-a ")
        stage.window.settle()
        return .image(try stage.pictureWithList(of: view))
    },
    GalleryState("list-scrolled", "twelve types, eight rows showing, the highlight moved down past them", size: tall) { stage in
        for (index, name) in ["Account", "Badge", "Company", "Department", "Employee", "Invoice", "Order", "Person", "Project", "Speaker", "Team", "Vendor"].enumerated() {
            _ = stage.editor.typeNote(name, schema: bareSchema, at: CGPoint(x: 280 + CGFloat(index % 3) * 110, y: 40 + CGFloat(index / 3) * 70), width: 100, height: 60)
        }
        let ann = stage.editor.note("Ann Lee", title: "Ann", at: CGPoint(x: 40, y: 60))
        let view = try stage.edit(ann)
        stage.typeLine("/is-a ")
        for _ in 0..<9 { stage.window.press("\u{F701}", code: 125) }
        stage.window.settle()
        return .image(try stage.pictureWithList(of: view))
    },
    GalleryState("list-untitled-type", "a type with no title in the list: `Untitled`, gray, no color", size: tall) { stage in
        _ = stage.editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: 280, y: 60), width: 130, height: 160)
        _ = stage.editor.typeNote(nil, schema: bareSchema, at: CGPoint(x: 430, y: 60), width: 130, height: 160)
        let ann = stage.editor.note("Ann Lee", title: "Ann", at: CGPoint(x: 40, y: 60))
        let view = try stage.edit(ann)
        stage.typeLine("/is-a ")
        stage.window.settle()
        return .image(try stage.pictureWithList(of: view))
    },
    GalleryState("list-arrow-label", "an arrow's label: `/is-a` lists the types and no `Type` row", size: tall) { stage in
        _ = someTypes(stage, from: 40, y: 250, width: 110)
        let arrow = stage.editor.add(Arrow(start: .free(CGPoint(x: 60, y: 80)), end: .free(CGPoint(x: 420, y: 80)), text: "keep"))
        let view = try stage.edit(arrow)
        stage.typeLine("/is-a ")
        stage.window.settle()
        return .image(try stage.pictureWithList(of: view))
    },
    GalleryState("read-only-note", "a locked note: no list, a `/` is a `/`; its menu still shows Is a ▸ (see read-only-menu)") { stage in
        let ann = stage.editor.note("Ann Lee, staff engineer", title: "Ann", at: CGPoint(x: 40, y: 70))
        _ = someTypes(stage, from: 280, y: 70, width: 110)
        stage.editor.lock([ann])
        stage.editor.selection = nil
        return board(stage)
    },
    GalleryState("read-only-menu", "the menu of a locked note: Unlock and Is a ▸ with the types (outline)", isText: true) { stage in
        let ann = stage.editor.note("Ann Lee, staff engineer", title: "Ann", at: CGPoint(x: 40, y: 70))
        _ = someTypes(stage, from: 280, y: 70, width: 110)
        stage.editor.lock([ann])
        stage.editor.selection = ann
        return .text(stage.menuOutline(at: CGPoint(x: 140, y: 170)).joined(separator: "\n") + "\n")
    },
    GalleryState("chips-overflow", "more chips than fit: the ones that fit, then a gray `+N`", size: wide) { stage in
        let types = someTypes(stage, from: 300, y: 70, width: 100)
        let extra = stage.editor.typeNote("Contractor", schema: bareSchema, at: CGPoint(x: 300, y: 250), width: 100, height: 60)
        let more = stage.editor.typeNote("Manager", schema: bareSchema, at: CGPoint(x: 412, y: 250), width: 100, height: 60)
        let ann = stage.editor.note("Ann Lee", title: "Ann", at: CGPoint(x: 40, y: 70), width: 150)
        for type in [types.person, types.employee, types.speaker, extra, more] { stage.editor.addTypeLink(type, to: ann) }
        return board(stage)
    },
    GalleryState("chip-hover", "the pointer over a chip: its fill lightens") { stage in
        let person = stage.editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: 240, y: 70), width: 160, height: 180)
        let ann = stage.editor.note("Ann Lee", title: "Ann", at: CGPoint(x: 30, y: 70))
        stage.editor.addTypeLink(person, to: ann)
        _ = stage.render(at: .zero)
        let rect = try stage.editor.chip("Person", on: ann)
        stage.hover(at: stage.viewPoint(CGPoint(x: rect.midX, y: rect.midY)))
        return board(stage)
    },
    GalleryState("chip-pressed", "a chip pressed: its fill darkens") { stage in
        let person = stage.editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: 240, y: 70), width: 160, height: 180)
        let ann = stage.editor.note("Ann Lee", title: "Ann", at: CGPoint(x: 30, y: 70))
        stage.editor.addTypeLink(person, to: ann)
        _ = stage.render(at: .zero)
        let rect = try stage.editor.chip("Person", on: ann)
        stage.press(at: stage.viewPoint(CGPoint(x: rect.midX, y: rect.midY)))
        return board(stage)
    },
    GalleryState("zoomed-out-30", "a type note below 35%: a white rectangle with its title large in an ink that reads on it, a plain note beside it as before", size: wide) { stage in
        for (index, name) in ["Person", "Employee"].enumerated() {
            _ = stage.editor.typeNote(name, schema: bareSchema, at: CGPoint(x: 60 + CGFloat(index) * 360, y: 80), width: 300, height: 220)
        }
        _ = stage.editor.note("A plain note", title: "Ann", at: CGPoint(x: 780, y: 80), width: 300, height: 220)
        return .image(stage.render(at: .zero, zoom: 0.3))
    },
    GalleryState("zoomed-35", "the same at 35%: drawn in full, the pill and the words", size: wide) { stage in
        for (index, name) in ["Person", "Employee"].enumerated() {
            _ = stage.editor.typeNote(name, schema: bareSchema, words: index == 0 ? personWords : employeeWords, at: CGPoint(x: 60 + CGFloat(index) * 360, y: 80), width: 300, height: 220)
        }
        _ = stage.editor.note("A plain note", title: "Ann", at: CGPoint(x: 780, y: 80), width: 300, height: 220)
        return .image(stage.render(at: .zero, zoom: 0.35))
    },
    GalleryState("type-selected-and-invalid", "a selected type note and a type note whose schema is not JSON (the invalid ring), both on white", size: wide) { stage in
        let selected = stage.editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: 60, y: 70), width: 240, height: 180)
        _ = stage.editor.typeNote("Broken", schema: "{not json", words: "A broken schema.", at: CGPoint(x: 340, y: 70), width: 240, height: 180)
        stage.editor.selection = selected
        return board(stage)
    },
    GalleryState("type-being-edited", "a type note being edited: the editing view over the white paper") { stage in
        let id = stage.editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: 80, y: 70), width: 280, height: 200)
        _ = try stage.edit(id)
        return board(stage)
    },
    GalleryState("type-removed", "Remove Type: the note is yellow again, its pill gone", size: small) { stage in
        let id = stage.editor.typeNote("Person", schema: personSchema, words: personWords, at: CGPoint(x: 80, y: 70), width: 280, height: 200)
        stage.editor.removeType(id)
        stage.editor.selection = nil
        return board(stage)
    },
]

/// The types cut's states, for the suite: the look's, and one array a track (`GalleryRows`, `GalleryValues`, `GalleryPanel`, `GalleryCards`, `GalleryChecks`), so no two tracks touch one line.
@MainActor let galleryStates: [GalleryState] = galleryTypesLookStates + rowStates + valueStates + panelStates + cardStates + checkStates

@MainActor let galleryTests = Suite("Gallery", galleryDirectory == nil ? [
    test("one state renders in both appearances, and no state names a file twice") {
        let state = try require(galleryStates.first { $0.file == "Main-p1-type-note" })
        let made = try renderGalleryState(state, write: false)
        expectEqual(made.map(\.name), ["Main-p1-type-note-light.png", "Main-p1-type-note-dark.png"])
        guard case .image(let light) = made[0].output, case .image(let dark) = made[1].output else { throw GalleryFailure("pictures expected") }
        expect(!isBlank(light) && !isBlank(dark), "neither appearance is blank")
        expect(changedPixels(light, dark, in: CGRect(origin: .zero, size: state.size)) > 1000, "light and dark differ")
        let files = galleryStates.flatMap(\.files)
        expectEqual(files.count, Set(files).count, "no file twice")
    },
] : galleryStates.map { state in
    test(state.file) {
        _ = try renderGalleryState(state, write: true)
        writeGalleryIndex()
    }
})
