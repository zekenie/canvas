import AppKit
import CoreGraphics

/// Text shown beside part of the board while the pointer rests there: what a plugin says of what the
/// pointer is on (a type's words: the part of its schema they say). The host shows it over
/// everything the canvas shows, the editing view too, below its anchor (above, where there's no room
/// below), within the view, and it takes no clicks. One shows at a time (`CanvasEditor.popover`),
/// `Style.popoverDelay` after the pointer comes to what it's about (`hoverPopover`), or at once
/// while one shows or has just gone, as tooltips do.
@MainActor
public struct CanvasPopover {
    /// What it's about, as its plugin knows it: the pointer staying on the same thing keeps it.
    public let id: AnyHashable
    /// What it's beside, in world units.
    public internal(set) var anchor: CGRect
    /// What it says, in the plugin's fonts and colors: drawn in the canvas's appearance, so a color
    /// that follows the appearance follows it.
    public let text: NSAttributedString

    public init<ID: Hashable & Sendable>(id: ID, anchor: CGRect, text: NSAttributedString) {
        self.id = AnyHashable(id)
        self.anchor = anchor
        self.text = text
    }
}

extension CanvasEditor {
    /// The popover showing, if one is (`hoverPopover`): what the host draws.
    public var popover: CanvasPopover? { shownPopover }

    /// The pointer is on what `popover` is about, or on nothing that has one (nil), as it moves: the
    /// select tool's over the canvas (Selection's `ShapePopovers`), or over an editing view's own
    /// text (`EditContext.hoverPopover`). One about what shows, or what waits to, stays, at its
    /// anchor now; one about something else shows `Style.popoverDelay` from now, or at once while one
    /// shows or has gone within `Style.popoverWarmth`. Nil takes down what shows, and what waits. A
    /// press, a key on the canvas, the camera moving, editing beginning or ending, and another board
    /// or file shown take it down too, and the next waits its delay (`dismissPopover`).
    public func hoverPopover(_ popover: CanvasPopover?) {
        guard let popover else {
            popoverTimer?.cancel()
            popoverTimer = nil
            waitingPopover = nil
            guard shownPopover != nil else { return }
            shownPopover = nil
            popoverWarmth?.cancel()
            popoverWarmth = scheduler.schedule(after: Style.popoverWarmth) { [weak self] in self?.popoverWarmth = nil }
            delegate?.editorPopoverDidChange(self)
            return
        }
        if let shown = shownPopover, shown.id == popover.id {
            guard shown.anchor != popover.anchor else { return }
            shownPopover = popover
            delegate?.editorPopoverDidChange(self)
            return
        }
        if shownPopover != nil || popoverWarmth != nil {
            showPopover(popover)
            return
        }
        if waitingPopover?.id == popover.id {
            waitingPopover = popover
            return
        }
        waitingPopover = popover
        popoverTimer?.cancel()
        popoverTimer = scheduler.schedule(after: Style.popoverDelay) { [weak self] in
            guard let self, let waiting = waitingPopover else { return }
            showPopover(waiting)
        }
    }

    private func showPopover(_ popover: CanvasPopover) {
        popoverTimer?.cancel()
        popoverTimer = nil
        waitingPopover = nil
        popoverWarmth?.cancel()
        popoverWarmth = nil
        shownPopover = popover
        delegate?.editorPopoverDidChange(self)
    }

    /// Takes down the popover, and what waits: the person has gone on to something else (a press, a
    /// key, the camera moving, editing, another board), so the next waits its delay.
    func dismissPopover() {
        popoverTimer?.cancel()
        popoverTimer = nil
        waitingPopover = nil
        popoverWarmth?.cancel()
        popoverWarmth = nil
        guard shownPopover != nil else { return }
        shownPopover = nil
        delegate?.editorPopoverDidChange(self)
    }
}
