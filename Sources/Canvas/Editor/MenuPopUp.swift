import AppKit

extension CanvasEditor {
    /// Shows a menu under a rect of the board, as the host pops it up: a plugin's canvas button that
    /// opens a menu (a chip's) calls this from its click. The host pops it up on the next turn of the
    /// run loop, not inside the click, which is still bookkeeping the press it ends; a press that
    /// begins before that drops it. A menu asked for while another waits replaces it. In world units.
    /// With `highlighting` (one of the menu's items) it opens with that item highlighted, so Return
    /// takes it: AppKit positions the menu to put that item at the point (a list whose first item is
    /// the one most likely wanted).
    public func popUpMenu(_ menu: NSMenu, below worldRect: CGRect, highlighting item: NSMenuItem? = nil) {
        menuWaiting = (menu, worldRect, item)
        delegate?.editorMenuToPopUpDidChange(self)
    }

    /// The menu waiting for the host to pop it up, and the rect it opens below (world units).
    @_spi(Host) public var menuToPopUp: (menu: NSMenu, rect: CGRect)? { menuWaiting.map { ($0.menu, $0.rect) } }

    /// The item the menu waiting opens with highlighted, if it was asked for with one.
    @_spi(Host) public var menuItemToHighlight: NSMenuItem? { menuWaiting?.highlighting }

    /// The host is popping the menu up: it no longer waits.
    @_spi(Host) public func menuDidPopUp() { menuWaiting = nil }
}
