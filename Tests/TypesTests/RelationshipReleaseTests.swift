import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Selection
import TestKit
import Titles
import Topology
import Types

// What the release of a port's drag does with the arrow it drew (`connectionDrawn`), over bonds, the tests' own
// arrows: no Connections here, so what a release is made of is only what Types reads of an arrow's two ends.

/// Person, Company and a relationship type Employment from the one to the other (its ends drawn), a Person note
/// and a Company note.
@MainActor private struct Release {
    let editor: CanvasEditor
    let person: ShapeID, company: ShapeID, employment: ShapeID
    let ann: ShapeID, acme: ShapeID

    init(ends: Bool = true) throws {
        editor = try bondEditor()
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        employment = editor.addRelationshipType("Employment")
        ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 40, y: 400))
        acme = editor.addInstance("Acme", of: [company], at: CGPoint(x: 400, y: 400))
        if ends { drawEnds(of: employment) }
    }

    /// Person → the relationship type → Company.
    func drawEnds(of type: ShapeID) {
        editor.addBond(person, type)
        editor.addBond(type, company)
    }

    /// The words on a menu's rows; "" for a rule.
    func rows(of menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "" : $0.title } }

    func types(of bond: ShapeID) -> [ShapeID] { editor.typesOf(bond) }
}

@MainActor let releaseTests = Suite("The release of a port's drag", [
    test("an arrow between two notes that one relationship type fits takes it, as one step that Undo takes back, and opens no list") {
        let w = try Release()
        let bond = w.editor.addBond(w.ann, w.acme)
        let before = w.editor.document
        expectEqual(w.editor.connectionDrawn(bond), .took(w.employment))
        expectEqual(w.types(of: bond), [w.employment])
        expect(w.editor.menuToPopUp == nil, "no list")
        expectEqual(w.editor.undoHistory.undoName, TypesStyle.addType)
        w.editor.undo()
        expectEqual(w.editor.document, before, "one Undo takes the type back, the arrow stays")
        expectEqual(w.types(of: bond), [])
    },
    test("several fit: the list opens at the arrow, the taken types in name order, a rule, the open ones, a rule, a gray Plain arrow; the arrow is selected and the first row highlighted") {
        let w = try Release()
        let mentorship = w.editor.addRelationshipType("Mentorship", at: CGPoint(x: 800, y: 40))
        w.drawEnds(of: mentorship)
        let sponsor = w.editor.addRelationshipType("Sponsor", at: CGPoint(x: 800, y: 300))
        let bond = w.editor.addBond(w.ann, w.acme)
        let outcome = w.editor.connectionDrawn(bond)
        expectEqual(outcome, .offered(taken: [w.employment, mentorship], open: [sponsor]))
        expectEqual(w.editor.selection, bond, "the arrow is selected while the list is open")
        let (menu, rect) = try require(w.editor.menuToPopUp)
        expectEqual(w.rows(of: menu), ["Employment", "Mentorship", "", "Sponsor", "", "Plain arrow"])
        expect(w.editor.menuItemToHighlight === menu.items.first, "the first taken type is highlighted")
        let plain = try require(menu.items.last)
        expectEqual(plain.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .secondaryLabelColor)
        expect(menu.items[0].image != nil, "a small arrow in its color")
        expect(rect.width >= 0 && rect.height >= 0)
        expectEqual(w.types(of: bond), [], "nothing is given until a pick")
    },
    test("a pick is its own step, Add Type, after the arrow's: Undo returns to the plain arrow; Plain arrow, and a stale pick, change nothing") {
        // A menu performs an item's action through the application, which a test that runs alone has not made.
        _ = NSApplication.shared
        let w = try Release()
        let mentorship = w.editor.addRelationshipType("Mentorship", at: CGPoint(x: 800, y: 40))
        w.drawEnds(of: mentorship)
        let bond = w.editor.addBond(w.ann, w.acme)
        w.editor.connectionDrawn(bond)
        let menu = try require(w.editor.menuToPopUp).menu
        menu.performActionForItem(at: 1)
        expectEqual(w.types(of: bond), [mentorship])
        expectEqual(w.editor.undoHistory.undoName, TypesStyle.addType)
        w.editor.undo()
        expectEqual(w.types(of: bond), [])
        // Plain arrow: nothing.
        let untouched = w.editor.document
        menu.performActionForItem(at: menu.items.count - 1)
        expectEqual(w.editor.document, untouched)
        // Typed some other way while the list was open: the pick leaves it.
        w.editor.addTypeLink(w.employment, to: bond)
        let typed = w.editor.document
        menu.performActionForItem(at: 1)
        expectEqual(w.editor.document, typed, "retyped in the meantime")
        // Deleted: nothing happens.
        w.editor.transact("Delete") { $0.delete([bond]) }
        let gone = w.editor.document
        menu.performActionForItem(at: 0)
        expectEqual(w.editor.document, gone, "deleted in the meantime")
    },
    test("no relationship type fits, or only open ones do: the arrow stays plain and no list opens; one taken beside open ones is taken and opens none") {
        let w = try Release()
        let sponsor = w.editor.addRelationshipType("Sponsor", at: CGPoint(x: 800, y: 300))
        let ann2 = w.editor.addInstance("Bo", of: [w.person], at: CGPoint(x: 40, y: 600))
        let misfit = w.editor.addBond(w.ann, ann2)
        expectEqual(w.editor.connectionDrawn(misfit), .plain, "a Person to a Person fits nothing")
        expect(w.editor.menuToPopUp == nil)
        // Only the open relationship type, with no end drawn: offered by /is-a and Is a ▸, never taken.
        let lone = try Release(ends: false)
        let loneSponsor = lone.editor.addRelationshipType("Sponsor", at: CGPoint(x: 800, y: 300))
        let loneBond = lone.editor.addBond(lone.ann, lone.acme)
        expectEqual(lone.editor.connectionDrawn(loneBond), .plain)
        expect(lone.editor.menuToPopUp == nil)
        expectEqual(lone.types(of: loneBond), [])
        _ = loneSponsor
        // One taken with an open one beside it.
        let bond = w.editor.addBond(w.ann, w.acme)
        expectEqual(w.editor.connectionDrawn(bond), .took(w.employment))
        expect(w.editor.menuToPopUp == nil)
        _ = sponsor
    },
    test("a side with no end drawn fits a note of no type; against the type's direction nothing fits") {
        let w = try Release(ends: false)
        w.editor.addBond(w.person, w.employment)
        let plain = w.editor.addInstance("Just a note", of: [], at: CGPoint(x: 400, y: 600))
        let forward = w.editor.addBond(w.ann, plain)
        expectEqual(w.editor.connectionDrawn(forward), .took(w.employment), "the from end is drawn and Ann fits it; the other side is open")
        w.drawEnds(of: w.editor.addRelationshipType("Mentorship", at: CGPoint(x: 800, y: 40)))
        let backward = w.editor.addBond(w.acme, w.ann)
        expectEqual(w.editor.connectionDrawn(backward), .plain, "Acme to Ann runs against both types")
        expect(w.editor.menuToPopUp == nil)
    },
    test("a type's own note at either end, and a type-note pair with nothing that makes connections, leave the arrow plain") {
        let w = try Release()
        for bond in [w.editor.addBond(w.person, w.acme), w.editor.addBond(w.ann, w.company), w.editor.addBond(w.person, w.ann)] {
            expectEqual(w.editor.connectionDrawn(bond), .plain)
            expectEqual(w.types(of: bond), [])
        }
        // Two types, and nothing here makes a connection the way `canvas draw` does: nothing replaces the arrow.
        let bond = w.editor.addBond(w.person, w.company)
        let before = w.editor.document
        expectEqual(w.editor.connectionDrawn(bond), .plain)
        expectEqual(w.editor.document, before)
    },
    test("an end is read through a pill that stands for one shape; one that finds shapes, or may not stand for it yet, is not judged") {
        let w = try Release()
        let acmePill = w.editor.addRelay(standingFor: [w.acme], says: "Acme")
        let bond = w.editor.addBond(w.ann, acmePill)
        expectEqual(w.editor.connectionDrawn(bond), .plain, "the pill may not stand for Acme yet")
        w.editor.open(w.acme)
        expectEqual(w.editor.connectionDrawn(w.editor.addBond(w.ann, acmePill)), .took(w.employment), "and may")
        let query = w.editor.addRelay(standingFor: [w.acme, w.ann], says: "Some")
        expectEqual(w.editor.connectionDrawn(w.editor.addBond(w.ann, query)), .plain, "a pill that finds shapes")
        let empty = w.editor.addRelay(standingFor: [], says: "")
        expectEqual(w.editor.connectionDrawn(w.editor.addBond(w.ann, empty)), .plain, "a pill that stands for nothing")
    },
    test("an arrow that holds a type already, one not bound at both ends, and a shape that is no arrow are left alone") {
        let w = try Release()
        let typed = w.editor.addBond(w.ann, w.acme, of: [w.employment])
        let free = w.editor.addBond(w.ann, nil)
        let before = w.editor.document
        expectEqual(w.editor.connectionDrawn(typed), .plain)
        expectEqual(w.editor.connectionDrawn(free), .plain)
        expectEqual(w.editor.connectionDrawn(w.ann), .plain)
        expectEqual(w.editor.connectionDrawn(ShapeID()), .plain)
        expectEqual(w.editor.document, before)
        expect(w.editor.menuToPopUp == nil)
    },
    test("a release between a note and its relationship type is the same release whatever the relationship types in a file: the type of an arrow is its role, read from its ends alone") {
        let w = try Release()
        // Two ends of one relationship type: Person → Employment is a from end whatever else the file holds.
        let more = w.editor.addRelationshipType("Mentorship", at: CGPoint(x: 800, y: 40))
        let end = w.editor.addBond(w.person, more)
        expectEqual(w.editor.connectionDrawn(end), .end(more))
        expect(w.editor.relationships?.end(end) != nil)
        expectEqual(w.types(of: end), [], "an end is of nothing")
    },
])

@MainActor let endDrawTests = Suite("A drag from or to a relationship type", [
    test("a drag from a type to a relationship type is a from end, and from it to a type a to end: the arrow is left as drawn and no second relationship type is made") {
        let w = try Release(ends: false)
        let before = w.editor.document.shapes.count
        let toIt = w.editor.addBond(w.person, w.employment)
        expectEqual(w.editor.connectionDrawn(toIt), .end(w.employment))
        let fromIt = w.editor.addBond(w.employment, w.company)
        expectEqual(w.editor.connectionDrawn(fromIt), .end(w.employment))
        expectEqual(w.editor.document.shapes.count, before + 2, "the two arrows, nothing replaced and no type made")
        expectEqual(w.editor.relationships?.end(toIt)?.side, .from)
        expectEqual(w.editor.relationships?.end(fromIt)?.side, .to)
        expectEqual(w.types(of: toIt), [])
        // A second end of the same type on a side is allowed.
        let other = w.editor.addType(TypeSchemaProperty.starter, title: "Agency", at: CGPoint(x: 400, y: 200))
        let second = w.editor.addBond(w.employment, other)
        expectEqual(w.editor.connectionDrawn(second), .end(w.employment))
        expectEqual(w.editor.relationships?.graph.sides(of: w.employment).to.map(\.type), [w.company, other])
        expect(w.editor.menuToPopUp == nil)
    },
    test("relationship type to relationship type, a type to a note, a note to a type: plain") {
        let w = try Release()
        let mentorship = w.editor.addRelationshipType("Mentorship", at: CGPoint(x: 800, y: 40))
        for bond in [w.editor.addBond(w.employment, mentorship), w.editor.addBond(w.person, w.ann), w.editor.addBond(w.ann, w.person),
                     w.editor.addBond(w.employment, w.ann), w.editor.addBond(w.acme, w.employment)] {
            expectEqual(w.editor.connectionDrawn(bond), .plain)
            expectEqual(w.editor.relationships?.end(bond) == nil, true)
        }
    },
])
