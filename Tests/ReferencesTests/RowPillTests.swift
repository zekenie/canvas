import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Chrome
import Geometry
import Mentions
import Publishing
import References
import TestKit
import Titles
import Topology

// A pill for a row (reference version 2, `ReferenceTarget.row`): one that stands alone (an endpoint; none ships before the API
// kinds, so a ledger here, whose entries stand alone) is stood for by a pill of its own, which shows the row's live name and its
// lead under its shape's place line, is missing (dashed) once the row is gone while the shape is there, is made by name as a pick
// makes one (`standsIn(makesRow:)`), forwards to its shape at that row, and follows the row when it moves to another shape.

/// A ledger: titled, mentionable, public by choice, with entries that stand alone and lead with a bolt.
private struct Ledger: BoxShapeProps {
    static let kind: ShapeKind = "ledger"
    static let properties = Properties<Ledger> {
        Property("frame", \.frame).required()
        Property("rows", \.rows)
    }
    var frame: CGRect
    var rows: [RosterRow]
    init(_ frame: CGRect = boxFrame, rows: [RosterRow] = []) {
        self.frame = frame
        self.rows = rows
    }
    init() { self.init(boxFrame) }
}

private struct LedgerDefinition: ShapeDefinition, PartedShape {
    func render(_ shape: ShapeRecord<Ledger>, in context: RenderContext) {}

    func parts(of shape: ShapeRecord<Ledger>) -> [PartName] {
        shape.props.rows.map { PartName(id: $0.id, name: $0.name, kindWord: "Entry", lead: .symbol("bolt"), standsAlone: true) }
    }
}

private let ledgers = Contributor(id: "ledgers") { registrar in
    registrar.shape(LedgerDefinition()) { _ in }
    registrar.title(Ledger.self)
    registrar.mentionable(Ledger.self, symbol: { _ in "book" }, tint: { _ in .systemTeal })
}

@MainActor private struct Books {
    let h: EditorHarness
    let refund = RosterRow(name: "POST /refunds"), charge = RosterRow(name: "POST /charges")
    let ledger: ShapeID, other: ShapeID

    init() throws {
        h = try referenceHarness([PocketsPlugin(), pocketTitles, ledgers])
        let refund = refund, charge = charge
        ledger = h.add(Ledger(CGRect(x: 100, y: 100, width: 200, height: 100), rows: [refund, charge]))
        other = h.add(Ledger(CGRect(x: 100, y: 500, width: 200, height: 100), rows: []))
        h.editor.transact { tx in
            tx.update(ledger) { $0[TitleProperty.self] = "Stripe API" }
            tx.update(other) { $0[TitleProperty.self] = "Ledger Two" }
        }
    }

    /// A pill for `row` of the ledger, made as a pick makes one, at `origin`.
    func pill(for row: PartID, label: String, at origin: CGPoint = pillOrigin) -> ShapeID {
        var props = Reference(frame: CGRect(origin: origin, size: Reference.defaultSize))
        ReferenceEdits.pick(&props, ReferenceTarget(id: ledger, label: label, row: row))
        return h.add(props)
    }
}

@MainActor let rowPillTests = Suite("A pill for a row", [
    test("it stands for its shape at that row: live with the row's name, its lead and its kind word; it follows a rename with nothing written") {
        let b = try Books()
        let pill = b.pill(for: b.refund.id, label: "POST /refunds")
        guard case .live(let appearance)? = b.h.state(of: pill) else { return expect(false, "\(String(describing: b.h.state(of: pill)))") }
        expectEqual(appearance.label, "POST /refunds")
        expectEqual(appearance.systemImage, "bolt", "the row's lead")
        expectEqual(appearance.kindName, "Entry")
        let topology = try require(b.h.editor.topology)
        expectEqual(topology.forwarding(of: pill), .record([b.ledger]), "it stands for the ledger")
        expectEqual(topology.directPart(of: pill), b.refund.id, "at its row")
        b.h.editor.transact { $0.update(b.ledger, as: Ledger.self) { $0.props.rows[0].name = "POST /refunds/{id}" } }
        guard case .live(let renamed)? = b.h.state(of: pill) else { return expect(false) }
        expectEqual(renamed.label, "POST /refunds/{id}", "the row's live name")
        expectEqual(b.h.reference(pill)?.target?.label, "POST /refunds", "nothing written to the pill")
    },
    test("its row gone while the shape is there: missing, dashed, its stored name; the shape gone: missing too; undone, live again") {
        let b = try Books()
        let pill = b.pill(for: b.refund.id, label: "POST /refunds")
        b.h.editor.transact { $0.update(b.ledger, as: Ledger.self) { $0.props.rows = [b.charge] } }
        expectEqual(b.h.state(of: pill), .missing(label: "POST /refunds"))
        b.h.editor.undo()
        guard case .live? = b.h.state(of: pill) else { return expect(false) }
        b.h.editor.transact { $0.delete([b.ledger]) }
        expectEqual(b.h.state(of: pill), .missing(label: "POST /refunds"))
    },
    test("it says its shape's place over the row's name, its shape last: Stripe API on the same board; drawn in two lines") {
        let b = try Books()
        let pill = b.pill(for: b.refund.id, label: "POST /refunds")
        b.h.editor.transact { $0.update(pill, as: Reference.self) { $0.props.frame.size.width = 200 } }
        let drawn = render(b.h.editor)
        let state = try require(b.h.editor.references)
        expectEqual(state.drawnPlace(of: pill)?.text, "Stripe API", "the shape it's in, over the row's name")
        let frame = try require(b.h.editor.document[pill]?.box)
        var top = 0
        for y in 7..<18 {
            for x in 32..<150 where pixel(drawn, at: CGPoint(x: frame.minX + CGFloat(x), y: frame.minY + CGFloat(y))).contains(where: { $0 < 200 }) { top += 1 }
        }
        expect(top > 20, "a place line is drawn over the name")
        expectEqual(b.h.editor.accessibleDescription(of: pill)?.label, "POST /refunds, Reference, Entry, in Stripe API", "read as a row in a list is")
    },
    test("made by name for a row (`standsIn(makesRow:)`), fitted to the row's name; a kind made by name for a shape stands for it whole") {
        let b = try Books()
        let standIns = b.h.editor.registry.standIns
        expect(standIns.makesRows(Reference.kind))
        let made = try require(standIns.make(Reference.kind, standingFor: b.ledger, row: b.refund.id, label: "POST /refunds"))
        let props = try require(made.typed(as: Reference.self)?.props)
        expectEqual(props.target, ReferenceTarget(id: b.ledger, label: "POST /refunds", row: b.refund.id))
        expectEqual(props.frame.width, ReferenceEdits.width(of: props), "fitted as a pick fits it")
        expectEqual(standIns.forwarding(of: made), .row(b.ledger, b.refund.id))
        let whole = try require(standIns.make(Reference.kind, standingFor: b.ledger, label: "Stripe API"))
        expectEqual(standIns.forwarding(of: whole), .shapes([b.ledger]))
    },
    test("a row moved to another shape (`moveParts`): the pill follows it in the same step, on whichever board; undone, back") {
        let b = try Books()
        let pill = b.pill(for: b.refund.id, label: "POST /refunds")
        let moved = RosterRow(id: b.refund.id, name: b.refund.name)
        b.h.editor.transact("Take Out Entry") { tx in
            tx.update(b.ledger, as: Ledger.self) { $0.props.rows = [b.charge] }
            tx.update(b.other, as: Ledger.self) { $0.props.rows = [moved] }
            tx.moveParts([PartAddress(b.ledger, part: b.refund.id): PartAddress(b.other, part: moved.id)])
        }
        expectEqual(b.h.reference(pill)?.target?.id, b.other, "the pill stands for where the row went")
        expectEqual(b.h.reference(pill)?.target?.row, b.refund.id)
        guard case .live? = b.h.state(of: pill) else { return expect(false) }
        b.h.editor.undo()
        expectEqual(b.h.reference(pill)?.target?.id, b.ledger)
    },
    test("an arrow into a row pill is an edge into its shape at the row") {
        let b = try Books()
        let pill = b.pill(for: b.charge.id, label: "POST /charges")
        let box = b.h.addBox("Shop")
        b.h.connect(box, pill)
        let topology = try require(b.h.editor.topology)
        expectEqual(topology.edges(of: b.ledger, part: b.charge.id, .incoming, types: .only(WireEdge.id)).map(\.source), [box])
    },
])
