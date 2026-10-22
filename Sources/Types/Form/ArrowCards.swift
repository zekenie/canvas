import Adornments
import Canvas
import CoreGraphics
import Selection

// The card of an arrow's relationship: what the chip of a relationship type that has fields opens, and the only place its
// values are shown. It is the form every card is, over every field of the arrow's types (`FieldCardRequest.Target.shape`):
// type, Tab, Return, as in the card a note's row opens, each field its own undo step named for it (`Change Role`, the
// fold's rule). It hangs 4 points under the pill that leads the arrow's label (`RelationshipPill`), widened about its middle to
// the width an anchor has, else under the arrow's anchor (its label's frame, else the middle of its outline), and follows it as
// the notes it joins move; the arrow is selected while it is open, and is left selected as it closes by keys (Escape, Return on the
// blank last line, Tab off the last stop, ⇧Tab off the first), the canvas having the keyboard again, so the walk goes on from it.

extension CanvasEditor {
    /// Opens the card of an arrow's relationship, hung from where its adornments are anchored, and selects the arrow; asked
    /// again while it is open it closes (`FieldCards`' rule; a press on the chip of an open card is a press off the card, which
    /// the core closes it for, so the click that follows opens it afresh). False, with nothing changed, when none
    /// opens: the arrow is not on the board shown or is drawn as a skeleton (a card is refused zoomed out), or its types
    /// have no fields. Opening makes no step. A locked arrow's card opens to be read.
    @discardableResult
    public func openRelationshipCard(for arrow: ShapeID) -> Bool {
        guard let cards = fieldCards, document[arrow] != nil, let anchor = relationshipCardAnchor(of: arrow) else { return false }
        let request = FieldCardRequest(shape: arrow, target: .shape, mode: .values, isReadOnly: isReadOnly(arrow), rowRect: anchor,
                                       rowRectNow: { [weak self] in self?.relationshipCardAnchor(of: arrow) },
                                       closed: { [weak self] in self?.reselect(arrow) }, tabbedOut: { [weak self] _ in self?.reselect(arrow) })
        guard cards.open(request) else { return false }
        if selection != arrow { selection = arrow }
        return true
    }

    /// The card closed by a key: the arrow is the selection again, if it is still there.
    private func reselect(_ arrow: ShapeID) {
        guard document[arrow] != nil, selection != arrow else { return }
        selection = arrow
    }

    /// Where the card hangs from: the pill that leads the arrow's label, in world units, widened about its middle to what an
    /// anchor is (as the label's was), so the card is as wide and as placed as it always was; else the arrow's anchor.
    private func relationshipCardAnchor(of arrow: ShapeID) -> CGRect? {
        guard let pill = adornmentFrames(of: arrow).first(where: { $0.adornment == .of(RelationshipPill.self) })?.rect else {
            return adornmentAnchor(of: arrow)
        }
        let least = AdornmentLayout.minAnchorWidth * AdornmentLayout.scale(atZoom: CGFloat(zoomPercentage) / 100)
        guard pill.width < least else { return pill }
        return CGRect(x: pill.midX - least / 2, y: pill.minY, width: least, height: pill.height)
    }
}
