import AppKit
import CoreGraphics
import Geometry

/// A plugin's view shown under a rect of the board: sized in view points, following the camera, taking
/// clicks and keys. A row of a plugin's that holds more than a row can show opens into one.
/// The core knows nothing of what is in it: the host (`CanvasView`) frames the view and gives it the
/// keyboard, and the editor closes it as the person goes on to something else. One shows at a time
/// (`CanvasEditor.card`), over the editing view and everything else the canvas hosts but a popover.
@MainActor
public struct CanvasCard {
    /// What it is about, as its plugin knows it. Also the coalescing key of its undo step.
    public let id: AnyHashable
    /// The shape it hangs from, if one: it closes when that shape leaves the board or is drawn as a skeleton.
    public let shape: ShapeID?
    /// The rect it is under, world units.
    public internal(set) var anchor: CGRect
    /// The plugin's view. The host frames it; it pads and scrolls itself.
    public let view: NSView
    /// What gets the keyboard as it shows. Nil: the keyboard stays where it is.
    public let firstResponder: NSResponder?
    /// The step its commits are, from show to close (`transact(coalescing: id)`). Nil: it holds none.
    public internal(set) var stepName: String?
    /// Shown inside a press (or any action): the step that action made stays open when it ends, as the
    /// card's, so what the card commits is part of it, one Undo for both, after the card closes.
    /// The step keeps the action's name. Needs a `stepName`; a card shown outside an action is as
    /// any card.
    public let adoptsPress: Bool
    /// The size it wants, in view points, no larger than `room`. Asked each time it is laid out.
    public let size: @MainActor (_ room: CGSize) -> CGSize
    /// Called once, after it is taken down and the keyboard is back where it was.
    public let didClose: @MainActor (CanvasCardClosing) -> Void

    public init<ID: Hashable & Sendable>(id: ID, about shape: ShapeID? = nil, anchor: CGRect, view: NSView,
                                         firstResponder: NSResponder? = nil, stepName: String? = nil,
                                         adoptsPress: Bool = false,
                                         size: @escaping @MainActor (CGSize) -> CGSize,
                                         didClose: @escaping @MainActor (CanvasCardClosing) -> Void = { _ in }) {
        self.id = AnyHashable(id)
        self.shape = shape
        self.anchor = anchor
        self.view = view
        self.firstResponder = firstResponder
        self.stepName = stepName
        self.adoptsPress = adoptsPress
        self.size = size
        self.didClose = didClose
    }
}

/// Why a card closed.
public enum CanvasCardClosing: Sendable, Equatable {
    /// `closeCard()`, by its plugin.
    case asked
    /// Another card was shown.
    case replaced
    /// A press on the canvas or anywhere in the window, outside it and the rect it hangs from.
    case pressedElsewhere
    /// Editing began or ended.
    case editing
    /// Another board shown, or a file put in place.
    case board
    /// Undo or redo.
    case undo
    /// Its shape is drawn as a skeleton now.
    case skeleton
    /// A commit took its shape off the board.
    case shapeGone
    /// Its anchor is out of the view.
    case leftView
}

extension CanvasEditor {
    /// The card showing, if one is: what the host shows.
    public var card: CanvasCard? { shownCard }

    /// Shows it, in place of any other (which hears `.replaced`, before this one shows), and the host is
    /// told once. False, showing
    /// nothing and leaving any card showing as it is: its shape is not on the board shown, or is drawn
    /// as a skeleton (`drawsSkeleton(of:)`); with no shape, while `drawsSkeletons`. A shape being
    /// edited is drawn in full at any zoom, so a card on it shows.
    ///
    /// With a `stepName` its commits are one undo step from now until it closes: commit with
    /// `transact(nil, coalescing: card.id)`, outside any action (inside a press or a group a commit is
    /// that action's). A card shown inside a press (a face's click) holds the step for what is
    /// committed after the release, as a step of its own; one that `adoptsPress` holds the press's step
    /// itself, open past the release, so the press's changes and the card's are one Undo, once the card
    /// closes (while it has the keyboard, the Undo is its text field's). A commit from anywhere else
    /// ends that step and is a step of its own; the card's next commit makes another by the same name.
    @discardableResult
    public func showCard(_ card: CanvasCard) -> Bool {
        if let shape = card.shape {
            guard document[shape] != nil, !drawsSkeleton(of: shape) else { return false }
        } else if drawsSkeletons {
            return false
        }
        // The one it replaces is taken down without telling the host, which hears of the new one.
        if let old = shownCard {
            shownCard = nil
            undoHistory.letGo()
            old.didClose(.replaced)
        }
        shownCard = card
        if let name = card.stepName { undoHistory.keep(card.id, named: name, adopting: card.adoptsPress) }
        delegate?.editorCardDidChange(self)
        setNeedsDisplay()
        return true
    }

    /// Takes the card down, if one shows: `didClose(.asked)`.
    public func closeCard() { closeCard(.asked) }

    /// The host's, and the editor's own, with the reason: the keyboard is given back, the step it held
    /// closed, and then the plugin hears, last, so it acts on a settled editor.
    @_spi(Host) public func closeCard(_ reason: CanvasCardClosing) {
        guard let card = shownCard else { return }
        shownCard = nil
        undoHistory.letGo()
        delegate?.editorCardDidChange(self)
        setNeedsDisplay()
        card.didClose(reason)
    }

    /// The card showing is under `anchor` now (its row moved). Nothing, for the same rect; closes it if
    /// that is out of the view.
    public func moveCard(to anchor: CGRect) {
        guard var card = shownCard, card.anchor != anchor else { return }
        card.anchor = anchor
        shownCard = card
        cardFollowsCamera()
        if shownCard != nil { delegate?.editorCardDidChange(self) }
    }

    /// Its content wants another size: the host lays it out again.
    public func cardDidResize() {
        guard shownCard != nil else { return }
        delegate?.editorCardDidChange(self)
    }

    /// The step the card holds from now: nil holds none. Changing it closes the step it held.
    public func setCardStep(_ name: String?) {
        guard var card = shownCard else { return }
        undoHistory.letGo()
        card.stepName = name
        shownCard = card
        if let name { undoHistory.keep(card.id, named: name) }
    }

    /// Whether a press at a world point is on the rect the card hangs from: that rect is the card's own
    /// ground, so the press doesn't close it, and the plugin that showed it hears its own click.
    func pressIsOnCard(_ world: CGPoint) -> Bool { shownCard?.anchor.contains(world) == true }

    /// The camera, the zoom level or the view moved, or the card's anchor did: the card closes when
    /// its shape is drawn as a skeleton, or its anchor is out of the view, as the caret list closes
    /// when its anchor leaves the visible text. An empty viewport (a test that gave no size) closes
    /// nothing.
    func cardFollowsCamera() {
        guard let card = shownCard else { return }
        if card.shape.map(drawsSkeleton(of:)) ?? drawsSkeletons { return closeCard(.skeleton) }
        let view = unobscuredViewport
        if !view.isEmpty, !view.intersects(camera.toView(card.anchor)) { closeCard(.leftView) }
    }
}
