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
import Validation

// The gallery's states for types on the board (slice 6), appended to `relationStates`: board 2's frames 2.3 and 2.4 (a
// relationship type with several types on a side, and a type related to itself, its two ends named alike and named apart),
// frame 4.6's loose end (an end arrow its other end was freed from, orange), and a relationship type deleted with one locked
// end arrow left, orange, where the unlocked one went. The ring and the line are from the real check; a state throws when the
// board does not say what it draws.

private let boardStage = CGSize(width: 960, height: 520)
private let wideBoard = CGSize(width: 1_180, height: 520)
private let personType: FieldFixtures.TypeText = (rowsTypeID(95), "Person", "A person has a name.", fieldsSchema(["name"]))
private let companyType: FieldFixtures.TypeText = (rowsTypeID(96), "Company", "A company has a name.", fieldsSchema(["name"]))
private let agencyType: FieldFixtures.TypeText = (rowsTypeID(97), "Agency", "An agency has a name.", fieldsSchema(["name"]))
private let employmentID = rowsTypeID(98)
private let friendshipID = rowsTypeID(99)

extension CanvasEditor {
    /// A relationship type of this title, with no fields, at `origin`.
    @discardableResult
    fileprivate func putRelationshipType(_ id: ShapeID, titled title: String, at origin: CGPoint) -> ShapeID {
        let made = addTypeNote(TypeSchemaProperty.starter, text: "", title: title, frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), id: id)
        transact("Mark") { $0.update(made) { $0[RelationshipProperty.self] = true } }
        return made
    }

    /// An arrow's name, as typed on it.
    fileprivate func nameArrow(_ arrow: ShapeID, _ text: String) {
        transact("Typing") { $0.update(arrow, as: Arrow.self) { $0.props.text = MentionText(plain: text) } }
    }
}

@MainActor
private func lines(_ editor: CanvasEditor, _ id: ShapeID) -> [String] {
    _ = editor.validation?.results
    return editor.validation?.result(for: id)?.issues.map(\.message) ?? []
}

/// Person and Friendship, related to itself by two port drags, and a Person note under them.
@MainActor
private func friendsBoard(_ stage: GalleryStage, naming: (String, String)) throws -> (person: ShapeID, note: ShapeID, ends: (out: ShapeID, back: ShapeID)) {
    let editor = stage.editor
    let person = editor.put(personType, at: CGPoint(x: 40, y: 40))
    let friendship = editor.putRelationshipType(friendshipID, titled: "Friendship", at: CGPoint(x: 520, y: 40))
    let note = editor.instance(of: [person], words: "", ["name": "Ann Lee"], at: CGPoint(x: 40, y: 300))
    try stage.dragPort(from: person, to: friendship)
    let out = try editor.document.shapes.last { $0.kind == Arrow.kind }.map(\.id).orThrowGallery("the first arrow")
    try stage.dragPort(from: friendship, to: person)
    let back = try editor.document.shapes.last { $0.kind == Arrow.kind }.map(\.id).orThrowGallery("the second arrow")
    editor.nameArrow(out, naming.0)
    editor.nameArrow(back, naming.1)
    editor.selection = nil
    return (person, note, (out, back))
}

extension Optional {
    fileprivate func orThrowGallery(_ what: String) throws -> Wrapped {
        guard let self else { throw GalleryFailure("a \(what) on the board") }
        return self
    }
}

@MainActor
let selfStates: [GalleryState] = [
    GalleryState("Rel2-p3-several", answers: "Board 2, frame 2.3", "Employment with one arrow in from Person and two out, to Company and to Agency: any of them, `to` beside each unnamed end; a Person's `employment` row names both", size: boardStage) { stage in
        let editor = stage.editor
        let person = editor.put(personType, at: CGPoint(x: 40, y: 40))
        // Clear of both sides: an arrow between two shapes that touch has no body to see, and its `from` would be drawn
        // over the note it starts in.
        let company = editor.put(companyType, at: CGPoint(x: 620, y: 20))
        let agency = editor.put(agencyType, at: CGPoint(x: 620, y: 280))
        let employment = editor.putRelationshipType(employmentID, titled: "Employment", at: CGPoint(x: 410, y: 150))
        editor.galleryArrow(person, employment)
        editor.galleryArrow(employment, company)
        editor.galleryArrow(employment, agency)
        editor.selection = nil
        let sides = try require(editor.relationships?.graph.sides(of: employment))
        guard sides.from.map(\.type) == [person], sides.to.map(\.type) == [company, agency],
              editor.rowBook?.rows(of: person).last?.content == .relationType(direction: "→", chips: [company, agency], more: 0) else {
            throw GalleryFailure("two ends on the to side, and the type's row naming both")
        }
        return canvas(stage)
    },
    GalleryState("Rel2-p4-friends", answers: "Board 2, frame 2.4", "a Person related to itself by two arrows, one into Friendship and one back, bowed apart, both named `friends`: the type's one row `friends ↔ Person` and every Person's one `friends` row",
                 size: boardStage) { stage in
        let board = try friendsBoard(stage, naming: ("friends", "friends"))
        guard stage.editor.rowBook?.rows(of: board.note).map(\.name) == ["name", "friends"],
              stage.editor.rowBook?.rows(of: board.person).last?.content == .relationType(direction: "↔", chips: [board.person], more: 0),
              let back = stage.editor.document[board.ends.back]?.typed(as: Arrow.self), abs(back.props.bend) == 34 else {
            throw GalleryFailure("one `friends` row on the note, `↔` on the type, and the second arrow bowed")
        }
        return canvas(stage)
    },
    GalleryState("Rel2-p4-friends-apart", answers: "Board 2, frame 2.4", "the same two ends named apart, `friends` and `friend of`: two rows on every Person and on the type, `→` and `←`", size: boardStage) { stage in
        let board = try friendsBoard(stage, naming: ("friends", "friend of"))
        guard stage.editor.rowBook?.rows(of: board.note).map(\.name) == ["name", "friends", "friend of"],
              stage.editor.rowBook?.rows(of: board.person).suffix(2).map(\.name) == ["friends", "friend of"] else {
            throw GalleryFailure("two rows on the note and on the type")
        }
        return canvas(stage)
    },
    GalleryState("Rel4-p6-loose-end", answers: "Board 4, frame 4.6", "a loose end: the arrow from `in` to Layer, named `layer`, lost its other end when Layer was deleted; it stays, bound to `in` alone, with the orange ring",
                 size: wideBoard) { stage in
        let editor = stage.editor
        let feature = editor.put(featureType, at: CGPoint(x: 40, y: 40))
        let layer = editor.put(layerType, at: CGPoint(x: 800, y: 40))
        let relationship = editor.putRelationshipType(rowsTypeID(82), titled: "in", at: CGPoint(x: 520, y: 40))
        editor.galleryArrow(feature, relationship)
        let loose = editor.galleryArrow(relationship, layer)
        editor.nameArrow(loose, "layer")
        editor.transact("Delete") { $0.delete([layer]) }
        editor.selection = nil
        guard editor.document[loose] != nil, lines(editor, loose) == ["in isn’t attached at both ends."] else {
            throw GalleryFailure("the arrow is orange and says it is not attached at both ends")
        }
        return canvas(stage)
    },
    GalleryState("Rel4-p6-deleted-locked", answers: "Board 4, frame 4.6", "a relationship type deleted: the end arrow that was locked stays, let go of it where it was drawn, named `layer`, with the orange ring; the unlocked one went with the type",
                 size: wideBoard) { stage in
        let editor = stage.editor
        let feature = editor.put(featureType, at: CGPoint(x: 40, y: 40))
        let layer = editor.put(layerType, at: CGPoint(x: 800, y: 40))
        let relationship = editor.putRelationshipType(rowsTypeID(82), titled: "in", at: CGPoint(x: 520, y: 40))
        let locked = editor.galleryArrow(feature, relationship)
        editor.nameArrow(locked, "layer")
        let unlocked = editor.galleryArrow(relationship, layer)
        editor.lock([locked])
        editor.transact("Delete") { $0.delete([relationship]) }
        editor.selection = nil
        guard editor.document[relationship] == nil, editor.document[unlocked] == nil, editor.document[locked] != nil,
              lines(editor, locked) == ["This arrow isn’t attached at both ends."] else {
            throw GalleryFailure("the type and the unlocked arrow are gone, and the locked one is orange")
        }
        return canvas(stage)
    },
]
