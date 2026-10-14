import Adornments
import Canvas
import CoreGraphics
import Selection

// The card of an arrow's relationship: what the chip of a relationship type that has fields opens, and the only place its
// values are shown. It is the form every card is, over every field of the arrow's types (`FieldCardRequest.Target.shape`):
// type, Tab, Return, as in the card a note's row opens, each field its own undo step named for it (`Change Role`, the
// fold's rule). It hangs 4 points under the arrow's anchor (its label's frame, else the middle of its outline) and
// follows it as the notes it joins move; the arrow is selected while it is open.

extension CanvasEditor {
    /// Opens the card of an arrow's relationship, hung from where its adornments are anchored, and selects the arrow; asked
    /// again while it is open it closes (`FieldCards`' rule; a press on the chip of an open card is a press off the card, which
    /// the core closes it for, so the click that follows opens it afresh). False, with nothing changed, when none
    /// opens: the arrow is not on the board shown or is drawn as a skeleton (a card is refused zoomed out), or its types
    /// have no fields. Opening makes no step. A locked arrow's card opens to be read.
    @discardableResult
    public func openRelationshipCard(for arrow: ShapeID) -> Bool {
        guard let cards = fieldCards, document[arrow] != nil, let anchor = adornmentAnchor(of: arrow) else { return false }
        let request = FieldCardRequest(shape: arrow, target: .shape, mode: .values, isReadOnly: isReadOnly(arrow), rowRect: anchor,
                                       rowRectNow: { [weak self] in self?.adornmentAnchor(of: arrow) },
                                       closed: {}, tabbedOut: { _ in })
        guard cards.open(request) else { return false }
        if selection != arrow { selection = arrow }
        return true
    }
}
