import AppKit
import Chrome

// Held rows, VS Code's sticky scroll in its trees: as the rows nested under an open row scroll up past
// the list's top, its row stays there over them, and so does each open row they're nested under in
// turn, outermost first, one a level, so where the rows in view are shows however far into a frame's
// thousand notes the list is scrolled. The last row nested under a held row, going up, takes it up with
// it, under the row it's held under, and away. A held row is its row, drawn over the list's top as the
// outline draws it, and what's done to it is done to its row: a press scrolls the row into its place
// under the rows held above it and hands the press to the outline there, and the pointer and a drag
// over it are over its row. A row the keyboard reaches is scrolled clear of them.

/// Which rows the list holds at its top, and where, with its outline scrolled to a given top: worked out
/// from a few rows' levels a level (the outline's rows are all of one height), so it costs the rows held,
/// whatever's listed. Public for its tests, which hold it to VS Code's sticky scroll as it reads.
public struct ContentsHeldRows: Equatable {
    public struct Row: Equatable, CustomStringConvertible {
        /// Its place among the outline's rows.
        public var row: Int
        /// How far below the list's top it's drawn: its level's place, the rows held above it a row's
        /// height each, or less as the last row nested under it goes up past that.
        public var top: CGFloat

        public init(row: Int, top: CGFloat) {
            self.row = row
            self.top = top
        }

        public var description: String { "\(row)@\(top)" }
    }

    /// Outermost first, each nested under the one before.
    public var rows: [Row] = []
    /// The rows' height.
    public var height: CGFloat = 0

    /// How far below the list's top the rows held reach: the last's bottom, the rows before it each at
    /// its level's place.
    public var bottom: CGFloat { rows.last.map { $0.top + height } ?? 0 }

    /// Two places on the list nearer than this are one (a scroll's arithmetic leaves noise).
    public static let tolerance: CGFloat = 0.01

    /// The rows held over an outline of `count` rows `height` tall, the first's top at `start`, scrolled to
    /// `top` (the outline's points, down from its top), at most `capacity` of them, the outermost kept.
    /// `level(row)` is a row's level (0 at the top), `ancestor(row, level)` the row at `level` it's nested
    /// under (itself at its own level).
    public static func holding(top: CGFloat, start: CGFloat, height: CGFloat, count: Int, capacity: Int,
                               level: (Int) -> Int, ancestor: (Int, Int) -> Int?) -> ContentsHeldRows {
        var held = ContentsHeldRows(height: height)
        guard height > 0 else { return held }
        while held.rows.count < capacity {
            let depth = held.rows.count, slot = CGFloat(depth) * height
            // The row under the rows held so far, nested under the last of them.
            let y = top + slot - start + tolerance
            guard y >= 0 else { break }
            let under = Int((y / height).rounded(.down))
            guard under < count, level(under) >= depth, let row = ancestor(under, depth) else { break }
            // Deeper than `depth` while the next row is nested under the same row at `depth`.
            let next = under + 1 < count ? level(under + 1) : -1
            if row == under {
                // An open row with its rows after it, up past its place: held there, over them. Any other
                // shows as itself.
                guard next > depth, start + CGFloat(under) * height < top + slot - tolerance else { break }
                held.rows.append(Row(row: row, top: slot))
            } else if next > depth {
                held.rows.append(Row(row: row, top: slot))
            } else {
                // Its last row, going up, takes it up with it; nothing under it is held.
                held.rows.append(Row(row: row, top: min(slot, start + CGFloat(under + 1) * height - top - height)))
                break
            }
        }
        return held
    }
}

extension ContentsListController {
    /// Holds at the list's top the rows the rows under it are nested under, as the outline is scrolled
    /// now: on each scroll, each change to the outline's rows, and as an update ends.
    func holdRows() {
        view.placeHeldRows(reaching: view.held.show(heldRows(), outline: outline))
    }

    /// The rows held as the outline is scrolled now, at most `ContentsStyle.heldRowsMost` of them and
    /// `heldRowsShare` of the list's height.
    private func heldRows() -> ContentsHeldRows {
        let count = outline.numberOfRows
        guard count > 0 else { return ContentsHeldRows() }
        let first = outline.rect(ofRow: 0)
        return ContentsHeldRows.holding(top: view.listTop, start: first.minY, height: first.height, count: count,
                                        capacity: heldCapacity(height: first.height), level: { [outline] in outline.level(forRow: $0) },
                                        ancestor: { [outline] row, level in
            var item = outline.item(atRow: row), depth = outline.level(forRow: row)
            guard depth > level else { return depth == level ? row : nil }
            while depth > level, let up = outline.parent(forItem: item) {
                item = up
                depth -= 1
            }
            let found = outline.row(forItem: item)
            return depth == level && found >= 0 ? found : nil
        })
    }

    /// How many rows the list holds at most, rows `height` tall.
    private func heldCapacity(height: CGFloat) -> Int {
        guard height > 0 else { return 0 }
        return min(ContentsStyle.heldRowsMost, Int((view.listHeight * ContentsStyle.heldRowsShare / height).rounded(.down)))
    }

    /// A row the outline brought into view (a key's step, the selection shown) clear of the rows held over
    /// it: scrolled down, where they'd cover it, until it's under the rows held above it, which are those
    /// it's nested under, at most as many as are held (keyboard navigation's P7, focus shows).
    func showClearOfHeldRows(_ row: Int) {
        guard row >= 0, row < outline.numberOfRows else { return }
        let rect = outline.rect(ofRow: row)
        let above = CGFloat(min(outline.level(forRow: row), heldCapacity(height: rect.height))) * rect.height
        guard rect.minY < view.listTop + above - ContentsHeldRows.tolerance else { return }
        view.scrollList(toTop: rect.minY - above)
    }

    /// A press on a held row is its row's: the list scrolls the row into its place under the rows held
    /// above it, where it shows as itself, and hands the press on there, at the same place on the row. On
    /// its triangle it's the row's own triangle's, which opens or closes the row, the keyboard staying
    /// where it is; anywhere else it's the outline's, with the keyboard, as a press on a row gives it, so
    /// a click selects the row (the canvas taking the keyboard), a second opens it and a drag drags it.
    /// (A row going up shows only below its place, the row held above it covering the rest, so the press is
    /// on its row where it lands, and so is a double-click's next.)
    func pressHeldRow(_ event: NSEvent) {
        let point = outline.convert(event.locationInWindow, from: nil)
        guard let window = outline.window, let held = view.held.row(at: point, in: outline) else { return }
        let rect = outline.rect(ofRow: held.row)
        let at = CGPoint(x: point.x, y: rect.minY + point.y - (view.listTop + held.top))
        view.scrollList(toTop: rect.minY - CGFloat(held.level) * rect.height)
        guard let press = NSEvent.mouseEvent(with: event.type, location: outline.convert(at, to: nil), modifierFlags: event.modifierFlags,
                                             timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                             eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) else { return }
        if outline.frameOfOutlineCell(atRow: held.row).contains(at),
           let triangle = outline.rowView(atRow: held.row, makeIfNecessary: true)?.subviews.first(where: {
               $0.identifier == NSOutlineView.disclosureButtonIdentifier
           }) {
            triangle.mouseDown(with: press)
            return
        }
        window.makeFirstResponder(outline)
        outline.mouseDown(with: press)
    }

    /// The row shown at a point of the outline (its points), and its rect there: a held row, as it's
    /// drawn over the rows under it, else the outline's own (under the hairline under the held rows too);
    /// nil past the rows. What the pointer and a drag are over.
    func shownRow(at point: CGPoint) -> (item: Any, rect: CGRect)? {
        if let held = view.held.row(at: point, in: outline) { return (held.item, held.rect) }
        guard !view.held.covers(point, in: outline) else { return nil }
        let row = outline.row(at: point)
        guard row >= 0, let item = outline.item(atRow: row) else { return nil }
        return (item, outline.rect(ofRow: row))
    }
}

/// A held row where a point is: what the outline has there, its place among the outline's rows and its
/// level, how far below the list's top it's drawn, and its rect as drawn, in the outline's points.
struct ContentsHeldHit {
    let item: Any
    let row: Int
    let level: Int
    let top: CGFloat
    let rect: CGRect
}

/// The rows the list holds at its top, over the outline's (`ContentsHeldRows`): each drawn as the outline
/// draws its row (`ContentsTableRow`: the highlight, the hover's tint, a drop's ring and line; its triangle,
/// open, and its cell), on the sheet's surface, the inner under the outer so one going up goes under the
/// one it's held under, with a hairline under them all. It takes the pointer where it is, handing a press
/// to the list (`pressHeldRow`) and a drag over it to the outline, which asks the list what's shown there
/// (`shownRow(at:)`), and shows a held row's tooltip, its row's; assistive apps don't see it: what it draws
/// is the outline's own rows, read there.
@MainActor
final class ContentsHeldRowsView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("ContentsHeldRows")
    weak var list: ContentsListController?
    weak var outline: NSOutlineView?
    /// The rows shown, outermost first.
    private var shown: [ShownRow] = []
    /// Whether their highlight is the accent: the outline's has it while the outline has the keyboard
    /// in the key window (`outlineHasKeyboard`).
    private var isEmphasized = false

    /// A held row's views, and what its cell shows: its item (a row, or a section's row), the shape's
    /// row as made (remade, its shape changed), a section's count, and the rows' size.
    @MainActor
    private final class ShownRow {
        let view = ContentsTableRow()
        let cell = ContentsCell()
        let triangle: NSButton?
        weak var item: AnyObject?
        var shapeRow: ShapeRow?
        var count = 0
        var size: NSTableView.RowSizeStyle?
        var row = 0
        var level = 0
        var top: CGFloat = 0

        init(triangle: NSButton?) {
            self.triangle = triangle
            view.paintsSurface = true
            view.addSubview(cell)
            guard let triangle else { return }
            // Drawn only: a press on it is the held row's, which hands it to the row's own triangle.
            triangle.target = nil
            triangle.action = nil
            triangle.state = .on
            view.addSubview(triangle)
        }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        clipsToBounds = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows `held`: its rows where they're drawn below its top, the list's, each as the outline draws
    /// it, its cell shown afresh only when what it shows changed; as far as the outline has their items.
    /// How far down they reach.
    @discardableResult
    func show(_ held: ContentsHeldRows, outline: NSOutlineView) -> CGFloat {
        let places = Array(held.rows.prefix { outline.item(atRow: $0.row) != nil })
        while shown.count > places.count, let gone = shown.popLast() {
            gone.view.removeFromSuperview()
            gone.view.show(nil)
        }
        while shown.count < places.count {
            let row = ShownRow(triangle: outline.makeView(withIdentifier: NSOutlineView.disclosureButtonIdentifier, owner: nil) as? NSButton)
            row.view.list = list
            // Under the rows held above it, which cover it as it goes up.
            addSubview(row.view, positioned: .below, relativeTo: nil)
            shown.append(row)
        }
        isHidden = places.isEmpty
        let size = outline.effectiveRowSizeStyle
        let width = outline.bounds.width
        for (kept, place) in zip(shown, places) {
            guard let item = outline.item(atRow: place.row) else { continue }
            let rect = outline.rect(ofRow: place.row)
            kept.row = place.row
            kept.level = outline.level(forRow: place.row)
            kept.top = place.top
            kept.view.frame = CGRect(x: 0, y: place.top, width: width, height: rect.height)
            kept.cell.frame = outline.frameOfCell(atColumn: 0, row: place.row).offsetBy(dx: 0, dy: -rect.minY)
            kept.triangle?.frame = outline.frameOfOutlineCell(atRow: place.row).offsetBy(dx: 0, dy: -rect.minY)
            switch item {
            case let row as ContentsItem where kept.item !== row || kept.shapeRow !== row.entry.row || kept.size != size:
                kept.item = row
                kept.shapeRow = row.entry.row
                kept.size = size
                kept.cell.show(row.entry, size: size)
                kept.view.show(row)
                countShown()
            case let section as ContentsSectionItem where kept.item !== section || kept.count != section.rows.count || kept.size != size:
                kept.item = section
                kept.shapeRow = nil
                kept.count = section.rows.count
                kept.size = size
                kept.cell.show(section.key.section, count: section.rows.count, size: size)
                kept.view.show(section: section)
                countShown()
            default:
                break
            }
        }
        isEmphasized = outlineHasKeyboard
        showSelection()
        return places.last.map { $0.top + held.height } ?? 0
    }

    /// Whether the outline has the keyboard in the key window, when its highlight is the accent.
    private var outlineHasKeyboard: Bool {
        guard let outline, let window = outline.window else { return false }
        return window.isKeyWindow && window.firstResponder === outline
    }

    /// Counts a held row shown afresh (debug builds: `ContentsState.heldRowsShown`).
    private func countShown() {
        #if DEBUG
        list?.state.heldRowsShown += 1
        #endif
    }

    /// The rows' highlight as the outline's: a held row's selected while its row is.
    func showSelection() {
        guard let outline else { return }
        for kept in shown {
            let selected = outline.isRowSelected(kept.row)
            if kept.view.isSelected != selected { kept.view.isSelected = selected }
            if kept.view.isEmphasized != isEmphasized { kept.view.isEmphasized = isEmphasized }
        }
    }

    /// The outline took the keyboard, or gave it up, or its window became key or stopped being: the
    /// highlight follows, as the outline's does.
    func emphasize(_ emphasized: Bool) {
        isEmphasized = emphasized
        showSelection()
    }

    /// The held row at a point of the outline (its points), the outer over the inner.
    func row(at point: CGPoint, in outline: NSOutlineView) -> ContentsHeldHit? {
        guard !isHidden else { return nil }
        let local = convert(point, from: outline)
        guard bounds.contains(local) else { return nil }
        for kept in shown where kept.view.frame.contains(local) {
            guard let item = kept.item else { return nil }
            return ContentsHeldHit(item: item, row: kept.row, level: kept.level, top: kept.top,
                                   rect: outline.convert(kept.view.frame, from: self))
        }
        return nil
    }

    /// Whether the held rows cover a point of the outline (its points); the hairline under them is over
    /// the row under it, which takes a press there.
    func covers(_ point: CGPoint, in outline: NSOutlineView) -> Bool {
        let local = convert(point, from: outline)
        return !isHidden && bounds.contains(local) && local.y < bounds.height - ChromeStyle.hairlineWidth
    }

    /// The hairline under the held rows, as under the list's header.
    override func draw(_ dirtyRect: NSRect) {
        ChromeStyle.hairline.setFill()
        NSBezierPath.fill(CGRect(x: 0, y: bounds.height - ChromeStyle.hairlineWidth, width: bounds.width, height: ChromeStyle.hairlineWidth))
    }

    // MARK: The pointer

    /// One tooltip over all of it, which says the held row's under the pointer (`view(_:stringForToolTip:…)`).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    /// A press on the held rows is the list's, none its views'.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let outline, frame.contains(point), let superview else { return nil }
        return covers(outline.convert(point, from: superview), in: outline) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        list?.pressHeldRow(event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        outline?.acceptsFirstMouse(for: event) ?? false
    }

    /// The tooltip of the held row at `point` (its own points): its row's (`ContentsLabel.help`), none for a
    /// section's row or a row that says nothing more.
    func toolTip(at point: CGPoint) -> String {
        guard let row = shown.first(where: { $0.view.frame.contains(point) }), let item = row.item as? ContentsItem else { return "" }
        return item.entry.label?.help ?? ""
    }

    // MARK: Drags, the outline's

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { outline?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { outline?.draggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { outline?.draggingExited(sender) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { outline?.prepareForDragOperation(sender) ?? false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { outline?.performDragOperation(sender) ?? false }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { outline?.concludeDragOperation(sender) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { outline?.draggingEnded(sender) }
    override func wantsPeriodicDraggingUpdates() -> Bool { outline?.wantsPeriodicDraggingUpdates() ?? true }

    // MARK: The window

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowKeyChanged(_ notification: Notification) {
        emphasize(outlineHasKeyboard)
    }

    // MARK: Assistive apps

    /// Not there for assistive apps: the rows it draws are the outline's, which VoiceOver walks.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        // AppKit asks on the main thread; the method is declared without the main actor.
        nonisolated(unsafe) var element: Any?
        MainActor.assumeIsolated { element = outline }
        return element
    }
}

extension ContentsHeldRowsView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTip(at: point)
    }
}
