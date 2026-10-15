import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import Mentions
import References
import Selection
import StickyNotes
import TestKit
import Titles
import Types
import Validation

// The gallery's states for a relationship on its arrow and in the note's card (slice 5), appended to `relationStates`: frames 3.4
// to 3.7 of board 3 at three arrow lengths (349, 229 and 123 between the notes' edges, as the drawing's), at 100% and at 50%, light
// and dark: the arrow's card under the arrow, and the chip saying how many fields (the values are shown nowhere on the board:
// the owner's call on 2026-10-14, which took away the line of values these frames first drew); frame 4.3, the card the note's
// `friends` row opens; and the check's states an earlier slice left undrawn, frames 5.1 and 5.2: a misfit (the ring, the red chip,
// the Issues sentence), an end that cannot be read, a free end, and a loose end; and the chip on slanted arrows (`Rel3-p6-slant`):
// five arrows of one relationship type at 0, 20 falling, 35 falling, 35 rising and 70 degrees, one with words.

private let person: FieldFixtures.TypeText = (rowsTypeID(95), "Person", "A person has a name.", fieldsSchema(["name"], required: ["name"]))
private let company: FieldFixtures.TypeText = (rowsTypeID(96), "Company", "A company has a name.", fieldsSchema(["name"]))
private let layerOfThree: FieldFixtures.TypeText = (rowsTypeID(97), "Layer", "A layer has an order and a title.", fieldsSchema(["order", "title"]))
private let employmentID = rowsTypeID(98)
private let friendshipID = rowsTypeID(99)
private let employmentSchema = #"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string"}, "until": {"type": "string"}, "hours": {"type": "number"}}}"#
private let friendshipSchema = #"{"type": "object", "properties": {"since": {"type": "string"}}, "required": ["since"]}"#

private let farAway = CGPoint(x: 4_000, y: 4_000)

/// A Person, a Company and Employment, a relationship type that holds a role, dates and hours, with its two ends, off the stage.
@MainActor
private func employmentTypes(_ stage: GalleryStage) {
    let editor = stage.editor
    editor.put(person, at: farAway)
    editor.put(company, at: CGPoint(x: farAway.x + 400, y: farAway.y))
    editor.put(layerOfThree, at: CGPoint(x: farAway.x + 1_200, y: farAway.y))
    let related = editor.addTypeNote(employmentSchema, text: "A job: a role, held since a date.", title: "Employment",
                                     frame: CGRect(x: farAway.x + 800, y: farAway.y, width: 200, height: 200), id: employmentID)
    editor.transact("Mark") { $0.update(related) { $0[RelationshipProperty.self] = true } }
    editor.galleryArrow(person.id, employmentID)
    editor.galleryArrow(employmentID, company.id)
}

/// Ann and Acme, `length` apart edge to edge, and an Employment arrow from one to the other holding `values`.
@MainActor
private func jobBoard(_ stage: GalleryStage, length: CGFloat, values: JSONObject) -> (ann: ShapeID, acme: ShapeID, arrow: ShapeID) {
    let editor = stage.editor
    employmentTypes(stage)
    let ann = editor.instance(of: [person.id], words: "", ["name": "Ann Lee"], at: CGPoint(x: 40, y: 80))
    let width = (editor.shapeContext.frame(of: ann)?.width ?? 320)
    let acme = editor.instance(of: [company.id], words: "", ["name": "Acme"], at: CGPoint(x: 40 + width + length, y: 80))
    let arrow = editor.galleryArrow(ann, acme, of: employmentID)
    for (key, value) in values { editor.fieldWriter?.set(value, at: FieldPath(field: key), of: arrow) }
    editor.selection = nil
    stage.look(at: .zero)
    return (ann, acme, arrow)
}

private let employmentValues: JSONObject = ["role": "engineer", "since": "2021", "until": "2027", "hours": 32]

/// The number on an arrow's relationship chip, and whether the chip is all that is shown of it.
@MainActor
private func chipNumber(_ stage: GalleryStage, _ arrow: ShapeID) -> (number: Int?, alone: Bool) {
    let frames = stage.editor.adornmentFrames(of: arrow)
    return (frames.first { $0.adornment == .of(TypeChips.self) }?.label.count, frames.allSatisfy { $0.adornment == .of(TypeChips.self) })
}

/// Where the states of one arrow length and zoom are written: the stage is as wide as the board at that zoom.
private func armSize(length: CGFloat, zoom: CGFloat) -> CGSize {
    CGSize(width: ((40 + 320 + length + 320 + 40) * zoom).rounded(.up), height: (zoom == 1 ? 460 : 340))
}

private let lengths: [CGFloat] = [349, 229, 123]

@MainActor
private func arrowStates() -> [GalleryState] {
    var states: [GalleryState] = []
    for length in lengths {
        for (zoom, tag) in [(CGFloat(1), "z100"), (0.5, "z50")] {
            let size = armSize(length: length, zoom: zoom)
            let name = "L\(Int(length))-\(tag)"
            states.append(GalleryState("Rel3-p5-chip-\(name)", answers: "Board 3, frames 3.5 and 3.7",
                                       "the arrow \(Int(length)) long between two notes at \(Int(zoom * 100))%, holding four values: the `Employment` chip saying 4, its fields, and nothing of the values on the board",
                                       size: size) { stage in
                let board = jobBoard(stage, length: length, values: employmentValues)
                stage.look(at: .zero, zoom: zoom)
                let chip = chipNumber(stage, board.arrow)
                guard chip.number == 4, chip.alone else { throw GalleryFailure("the chip says 4 and is all that is shown: \(chip)") }
                return .image(stage.render(at: .zero, zoom: zoom))
            })
            states.append(GalleryState("Rel3-p4-card-\(name)", answers: "Board 3, frame 3.4",
                                       "the same arrow with its card open under it, the arrow selected: the type's chip, `role`, `since`, `until` and `hours`",
                                       size: size) { stage in
                let board = jobBoard(stage, length: length, values: ["role": "engineer", "since": "2021"])
                stage.look(at: .zero, zoom: zoom)
                guard stage.editor.openRelationshipCard(for: board.arrow), stage.editor.fieldCards?.openTarget?.shape == board.arrow else {
                    throw GalleryFailure("the chip's card opens")
                }
                return .image(stage.picture())
            })
        }
    }
    return states
}

// MARK: Frame 4.3: the row's card

@MainActor
private func friendsBoard(_ stage: GalleryStage) throws -> (ann: ShapeID, friends: [ShapeID]) {
    let editor = stage.editor
    editor.put(person, at: farAway)
    let related = editor.addTypeNote(friendshipSchema, text: "A friendship: since when.", title: "Friendship",
                                     frame: CGRect(x: farAway.x + 400, y: farAway.y, width: 200, height: 200), id: friendshipID)
    editor.transact("Mark") { $0.update(related) { $0[RelationshipProperty.self] = true } }
    // Two arrows: one into Friendship and one back, so a Person is at both ends, both named friends.
    for (from, to) in [(person.id, friendshipID), (friendshipID, person.id)] {
        let id = editor.galleryArrow(from, to)
        editor.transact("Name") { $0.update(id, as: Arrow.self) { $0.props.text = MentionText(plain: "friends") } }
    }
    let ann = editor.instance(of: [person.id], words: "", ["name": "Ann Lee"], at: CGPoint(x: 40, y: 60))
    var friends: [ShapeID] = []
    for (place, (name, since)) in [("Bo Park", "2019"), ("Cy Diaz", "May 2021"), ("Dana Novak", nil)].enumerated() {
        let friend = editor.instance(of: [person.id], words: "", ["name": .string(name)], at: CGPoint(x: 520 + 340 * CGFloat(place % 2), y: 60 + 320 * CGFloat(place / 2)))
        let arrow = editor.galleryArrow(ann, friend, of: friendshipID)
        if let since { editor.fieldWriter?.set(.string(since), at: FieldPath(field: "since"), of: arrow) }
        friends.append(friend)
    }
    editor.selection = nil
    stage.look(at: .zero)
    return (ann, friends)
}


// MARK: Slanted arrows

/// The least distance from the arrow's body to any of its adornments, in view points at `zoom`.
@MainActor
private func clearance(_ stage: GalleryStage, _ arrow: ShapeID, zoom: CGFloat) -> CGFloat {
    let outline = stage.editor.shapeContext.geometry(of: arrow)?.outline ?? []
    var least = CGFloat.infinity
    for frame in stage.editor.adornmentFrames(of: arrow) {
        for (from, to) in zip(outline, outline.dropFirst()) {
            let length = hypot(to.x - from.x, to.y - from.y)
            for step in 0...Int(length) {
                let t = length == 0 ? 0 : CGFloat(step) / length
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                let dx = max(frame.rect.minX - p.x, 0, p.x - frame.rect.maxX), dy = max(frame.rect.minY - p.y, 0, p.y - frame.rect.maxY)
                least = min(least, hypot(dx, dy) * zoom)
            }
        }
    }
    return least
}

@MainActor
private func slantState() -> GalleryState {
    // Degrees below the horizontal (a rising arrow is negative), the cell it is in, and whether it has words.
    let arrows: [(degrees: CGFloat, cell: (column: CGFloat, row: CGFloat), words: String?)] = [
        (0, (0, 0), nil), (20, (1, 0), nil), (35, (2, 0), nil), (-35, (0, 1), "works at"), (70, (1, 1), nil),
    ]
    let zoom: CGFloat = 0.4
    return GalleryState("Rel3-p6-slant", answers: "Board 3, frames 3.5 and 3.7 on a slanted arrow",
                        "five arrows of one relationship type between notes, at 0, 20 falling, 35 falling, 35 rising and 70 degrees, one with words on it: the chip above each arrow's anchor, saying how many fields, slides clear of the arrow's body, only as far as it must (the level one is as it was)",
                        size: CGSize(width: 1_400, height: 780)) { stage in
        let editor = stage.editor
        employmentTypes(stage)
        var made: [ShapeID] = []
        for (degrees, cell, words) in arrows {
            let radians = degrees * CGFloat.pi / 180
            let first = CGPoint(x: cell.column * 1_000 + 40, y: cell.row * 900 + (degrees < 0 ? 480 : 90))
            let ann = editor.instance(of: [person.id], words: "", ["name": "Ann Lee"], at: first)
            let acme = editor.instance(of: [company.id], words: "", ["name": "Acme"],
                                       at: CGPoint(x: first.x + 640 * cos(radians), y: first.y + 640 * sin(radians)))
            let arrow = editor.galleryArrow(ann, acme, of: employmentID)
            for (key, value) in employmentValues { editor.fieldWriter?.set(value, at: FieldPath(field: key), of: arrow) }
            if let words { editor.transact("Name") { $0.update(arrow, as: Arrow.self) { $0.props.text = MentionText(plain: words) } } }
            made.append(arrow)
        }
        editor.selection = nil
        stage.look(at: .zero, zoom: zoom)
        for arrow in made {
            let chip = chipNumber(stage, arrow)
            guard chip.number == 4, chip.alone else { throw GalleryFailure("each arrow shows its chip, saying 4, and nothing else: \(chip)") }
            guard clearance(stage, arrow, zoom: zoom) >= AdornmentLayout.margin - 0.5 else {
                throw GalleryFailure("the chip keeps clear of the body: \(clearance(stage, arrow, zoom: zoom))")
            }
        }
        return .image(stage.render(at: .zero, zoom: zoom))
    }
}

// MARK: The check's states

@MainActor
private func issues(_ stage: GalleryStage, _ id: ShapeID) -> [String] {
    stage.editor.validation?.result(for: id)?.issues.map(\.message) ?? []
}

@MainActor
let arrowCardStates: [GalleryState] = arrowStates() + [slantState()] + [
    GalleryState("Rel4-p3-row-card", answers: "Board 4, frame 4.3",
                 "a click on the `›` of Ann's `friends` row: a card under it, a line for each friendship, the friend as a pill and the relationship's own field, `since`; Dana's is empty and needed, so it says `add since` in amber; the blank line last",
                 size: CGSize(width: 1_000, height: 560)) { stage in
        let board = try friendsBoard(stage)
        guard let row = stage.editor.rowBook?.rows(of: board.ann).first(where: { $0.name == "friends" }),
              let chevron = stage.editor.rowBook?.chevronRect(of: row) else { throw GalleryFailure("Ann's `friends` row holds her three friends and ends in ›") }
        stage.editor.selection = board.ann
        stage.look(at: .zero)
        let point = stage.viewPoint(CGPoint(x: chevron.midX, y: row.rect.midY))
        stage.press(at: point)
        stage.release(at: point)
        stage.spin()
        stage.spin()
        guard case .relations? = stage.editor.fieldCards?.openTarget?.target, let form = stage.editor.fieldCards?.openForm, form.sheet.lines.count == 4 else {
            throw GalleryFailure("the click on › opened the card: a line for each friend and the blank one")
        }
        guard form.sheet.lines[2].cells.last?.mark == .needed || form.sheet.lines.contains(where: { $0.cells.last?.mark == .needed }) else {
            throw GalleryFailure("Dana's `since` is needed")
        }
        return .image(stage.picture())
    },
    GalleryState("Rel5-p1-misfit", answers: "Edges 5, frame 5.1",
                 "an Employment arrow re-aimed from a Company to a Layer note: the ring round the arrow and its chip red with a wave; nothing refused",
                 size: CGSize(width: 1_000, height: 900)) { stage in
        let editor = stage.editor
        let board = jobBoard(stage, length: 229, values: [:])
        let layer = editor.instance(of: [layerOfThree.id], words: "", ["order": 1, "title": "foundation"], at: CGPoint(x: 40 + 320 + 229, y: 520))
        editor.transact("Re-aim") { $0.update(board.arrow, as: Arrow.self) { $0.props.end = .bound(ArrowBinding(shapeID: layer, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) } }
        guard let chip = editor.adornmentFrames(of: board.arrow).first(where: { $0.adornment == .of(TypeChips.self) }), chip.label.isWrong,
              editor.validation?.result(for: board.arrow)?.isValid == false else { throw GalleryFailure("the chip is red and the arrow rings") }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel5-p1-misfit-issues", answers: "Edges 5, frame 5.1", "the Issues sentence of that arrow, naming the end", size: CGSize(width: 1_000, height: 460), isText: true) { stage in
        let editor = stage.editor
        let board = jobBoard(stage, length: 229, values: [:])
        let layer = editor.instance(of: [layerOfThree.id], words: "", ["order": 1, "title": "foundation"], at: CGPoint(x: 40 + 320 + 229, y: 520))
        editor.transact("Re-aim") { $0.update(board.arrow, as: Arrow.self) { $0.props.end = .bound(ArrowBinding(shapeID: layer, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) } }
        let said = issues(stage, board.arrow)
        guard said.count == 1, said[0].hasPrefix("Employment runs to a Company.") else { throw GalleryFailure("one sentence naming the end: \(said)") }
        return .text("arrow\n\(said.map { "error: \($0)" }.joined(separator: "\n"))\n")
    },
    GalleryState("Rel5-p2-unread-end", answers: "Edges 5, frame 5.2",
                 "an Employment arrow that ends on a pill for an Acme that is not public: orange, not red; the chip stays plain",
                 size: CGSize(width: 1_000, height: 460)) { stage in
        let editor = stage.editor
        let board = jobBoard(stage, length: 229, values: [:])
        let pill = editor.galleryPill(for: board.acme, label: "Acme", at: CGPoint(x: 40 + 320 + 229 + 40, y: 330))
        editor.transact("Re-aim") { $0.update(board.arrow, as: Arrow.self) { $0.props.end = .bound(ArrowBinding(shapeID: pill, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) } }
        guard let chip = editor.adornmentFrames(of: board.arrow).first(where: { $0.adornment == .of(TypeChips.self) }), !chip.label.isWrong else { throw GalleryFailure("the chip is plain") }
        guard issues(stage, board.arrow).first?.contains("isn’t public") == true else { throw GalleryFailure("an unread end is one warning: \(issues(stage, board.arrow))") }
        editor.selection = nil
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel5-p2-free-end", answers: "Edges 5, frame 5.2",
                 "an Employment arrow whose Company was deleted: the arrow stays, its end let go where it is drawn, orange",
                 size: CGSize(width: 1_000, height: 460)) { stage in
        let editor = stage.editor
        let board = jobBoard(stage, length: 229, values: [:])
        editor.transact("Delete") { $0.delete([board.acme]) }
        guard issues(stage, board.arrow).first?.contains("isn’t attached at both ends") == true else { throw GalleryFailure("a free end is one warning: \(issues(stage, board.arrow))") }
        editor.selection = nil
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel5-p2-loose-end", answers: "Edges 5, frame 5.2",
                 "the end arrow from Person into Employment after Person was deleted: it stays bound to Employment with its other end let go, orange",
                 size: CGSize(width: 1_100, height: 900)) { stage in
        let editor = stage.editor
        let types = (person: editor.put(person, at: CGPoint(x: 40, y: 40)), company: editor.put(company, at: CGPoint(x: 680, y: 40)))
        let related = editor.addTypeNote(employmentSchema, text: "A job.", title: "Employment", frame: CGRect(x: 360, y: 300, width: 200, height: 200), id: employmentID)
        editor.transact("Mark") { $0.update(related) { $0[RelationshipProperty.self] = true } }
        let end = editor.galleryArrow(types.person, related)
        editor.galleryArrow(related, types.company)
        editor.transact("Delete") { $0.delete([types.person]) }
        guard issues(stage, end).first?.contains("isn’t attached at both ends") == true else { throw GalleryFailure("a loose end is one warning: \(issues(stage, end))") }
        editor.selection = nil
        return .image(stage.render(at: .zero))
    },
]
