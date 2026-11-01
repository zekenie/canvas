import AppKit
import Canvas
import Chrome
import Observation
import Selection
import SwiftUI

// The table of contents' list's views (`ContentsList`): the outline and its scroll view, a row's view
// (its selection's highlight, its hover's tint, a drop's ring and line, its triangle's name), and the
// cell that hosts a row's view in SwiftUI.

/// The list's view: the outline in its scroll view, on the sidebar's background. It tells the list
/// when it's hidden (it, or a view it's in) or taken out of its window (the sidebar hidden), which
/// SwiftUI doesn't say.
@MainActor
final class ContentsListView: NSView {
    let scrollView = NSScrollView()
    let outline = ContentsTable()
    var onHide: (@MainActor () -> Void)?

    init() {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("contents"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.backgroundColor = .clear
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false
        outline.autosaveExpandedItems = false
        outline.usesAutomaticRowHeights = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // The list draws where a drag points (a line, a ring), not the outline.
        outline.draggingDestinationFeedbackStyle = .none
        outline.registerForDraggedTypes([.contentsRows])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        outline.sizeLastColumnToFit()
    }

    override func viewDidHide() {
        super.viewDidHide()
        onHide?()
    }

    /// Taken out of its window with the keyboard in its outline (the sidebar hidden): the list hands the
    /// canvas the keyboard (`onLeave`), which would fall to the window. Asked as it goes, of the window it
    /// leaves, which it keeps no hold of: a window going away takes its views out too.
    var onLeave: (@MainActor () -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === outline { onLeave?() }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// The list's outline: it hands each key to the list before handling it itself (Tab and ⇧Tab as ↓ and
/// ↑, Return, Delete, and the keys that give the canvas the keyboard), the pointer's moves (hover), and
/// a drag leaving it.
@MainActor
final class ContentsTable: NSOutlineView {
    weak var list: ContentsListController?
    private var tracking: NSTrackingArea?

    override func keyDown(with event: NSEvent) {
        guard let list else { return super.keyDown(with: event) }
        switch list.key(event) {
        case .handled:
            return
        case .step(let up):
            let arrow = String(UnicodeScalar(UInt16(up ? NSUpArrowFunctionKey : NSDownArrowFunctionKey))!)
            guard let step = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                              timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                              characters: arrow, charactersIgnoringModifiers: arrow, isARepeat: event.isARepeat,
                                              keyCode: up ? 126 : 125) else { return }
            super.keyDown(with: step)
        case .table:
            super.keyDown(with: event)
        }
    }

    /// ⌘., which the window sends up the responder chain with no key down: the keyboard to the canvas.
    override func cancelOperation(_ sender: Any?) {
        list?.exit()
    }

    /// Edit › Delete: the selected shapes deleted, as Delete in the list does.
    @objc func delete(_ sender: Any?) {
        list?.editor.perform(.delete)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(delete(_:)) { return list?.editor.canPerform(.delete) ?? false }
        return super.validateUserInterfaceItem(item)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracking == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        list?.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        list?.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        list?.endPointing()
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        list?.dragLeft()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        list?.dragLeft()
    }
}

/// A row's view behind its cell: its hover's tint and a drop's ring, in the selection highlight's
/// place, and a drop's line above or below it, each observed for its own shape alone
/// (`ContentsState.isHovered`, `dropZone(for:)`), so a hover redraws the row it leaves and the row it
/// reaches; and its disclosure triangle named for assistive apps by the row.
@MainActor
final class ContentsTableRow: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ContentsTableRow")
    weak var list: ContentsListController?
    private var shape: ShapeID?
    private var spokenName = ""
    private var isTinted = false
    private var zone: ContentsDropZone?
    /// Counts the looks begun, so a look begun for another shape (the row reused) is let be.
    private var looks = 0
    private let line = ContentsDropLineView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Shows a row (nil: none, the view put away): its name for its triangle, and its hover and drop.
    func show(_ item: ContentsItem?) {
        let id = item?.id
        spokenName = item?.entry.spokenName ?? ""
        nameTriangle()
        guard id != shape || id == nil else { return }
        shape = id
        look()
    }

    /// Shows a section's row: its title names its triangle; it has no shape to tint, nor to drop on.
    func show(section: ContentsSectionItem) {
        spokenName = section.key.section.title
        nameTriangle()
        guard shape != nil else { return }
        shape = nil
        look()
    }

    /// Reads the row's hover and drop, and is told once either changes, to read them again then.
    private func look() {
        looks += 1
        let look = looks
        guard let shape, let state = list?.state else { return showing(tinted: false, zone: nil) }
        let (tinted, zone) = withObservationTracking {
            (state.isHovered(shape), state.dropZone(for: shape))
        } onChange: { [weak self] in
            // Told as it's about to change: looked at once it has.
            Task { @MainActor in
                guard let self, self.looks == look else { return }
                self.look()
            }
        }
        showing(tinted: tinted, zone: zone)
    }

    private func showing(tinted: Bool, zone: ContentsDropZone?) {
        guard tinted != isTinted || zone != self.zone else { return }
        isTinted = tinted
        self.zone = zone
        needsDisplay = true
        if zone == .above || zone == .below {
            if line.superview !== self { addSubview(line) }
            placeLine()
        } else {
            line.removeFromSuperview()
        }
        #if DEBUG
        if shape != nil { list?.state.rowsRedrawn += 1 }
        #endif
    }

    /// Where a selected row's highlight is drawn, which the hover's tint and a drop's ring take.
    private var highlightRect: CGRect { bounds.insetBy(dx: ContentsStyle.highlightInset, dy: 0) }

    /// A selected row's highlight, rounded as the window's chrome rounds an item (the inspector's tabs
    /// too): the accent while the list has the keyboard, else the chrome's quiet fill.
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        (isEmphasized ? NSColor.selectedContentBackgroundColor : ChromeStyle.selectedFill).setFill()
        NSBezierPath(roundedRect: highlightRect, xRadius: ContentsStyle.highlightRadius, yRadius: ContentsStyle.highlightRadius).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isTinted || zone == .on else { return }
        let accent = NSColor.controlAccentColor
        if zone == .on {
            let ring = highlightRect.insetBy(dx: ContentsStyle.dropRingWidth / 2, dy: ContentsStyle.dropRingWidth / 2)
            let path = NSBezierPath(roundedRect: ring, xRadius: ContentsStyle.highlightRadius, yRadius: ContentsStyle.highlightRadius)
            accent.withAlphaComponent(ContentsStyle.dropTintOpacity).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = ContentsStyle.dropRingWidth
            path.stroke()
        } else {
            accent.withAlphaComponent(ContentsStyle.hoverOpacity).setFill()
            NSBezierPath(roundedRect: highlightRect, xRadius: ContentsStyle.highlightRadius, yRadius: ContentsStyle.highlightRadius).fill()
        }
    }

    override func layout() {
        super.layout()
        nameTriangle()
        if line.superview === self { placeLine() }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview is NSButton { nameTriangle() }
    }

    /// The line from the row's content's leading edge (where the cell starts, past the triangle and
    /// indentation, so it shows how deep the drop is) to the highlight's end, at the row's top for a
    /// drop above it, at its bottom for one below.
    private func placeLine() {
        let start = subviews.first { $0 is NSTableCellView }?.frame.minX ?? highlightRect.minX
        let height = ContentsStyle.dropLineDot
        let atTop = (zone == .above) == isFlipped
        line.frame = CGRect(x: start, y: atTop ? 0 : bounds.height - height, width: max(0, highlightRect.maxX - start), height: height)
    }

    /// Names the row's disclosure triangle for assistive apps by the row ("Checkout"; AppKit's role
    /// and value say it's a disclosure triangle, open or not), which the outline adds to the row and
    /// gives no name: as it's added, laid out, and as the row is reused.
    func nameTriangle() {
        for case let button as NSButton in subviews where button.identifier == NSOutlineView.disclosureButtonIdentifier {
            if button.accessibilityLabel() != spokenName { button.setAccessibilityLabel(spokenName) }
            if button.cell?.accessibilityLabel() != spokenName { button.cell?.setAccessibilityLabel(spokenName) }
        }
    }
}

/// A drop's line above or below a row, from a ring at its leading end, in the accent color, as a Mac
/// list's.
@MainActor
final class ContentsDropLineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let width = ContentsStyle.dropLineWidth, dot = ContentsStyle.dropLineDot
        let ring = NSBezierPath(ovalIn: CGRect(x: width / 2, y: (bounds.height - dot) / 2 + width / 2, width: dot - width, height: dot - width))
        ring.lineWidth = width
        accent.setStroke()
        ring.stroke()
        accent.setFill()
        CGRect(x: dot, y: bounds.midY - width / 2, width: max(0, bounds.width - dot), height: width).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A row's cell: the row as its kind drew it, with its marks (`ContentsRowView`), or a section's row
/// (`ContentsSectionLabel`), hosted in SwiftUI, reused for the rows that come into view; in white on a
/// selected row of a list with the keyboard, as a source list's text is.
@MainActor
final class ContentsCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ContentsCell")
    private let hosting = NSHostingView(rootView: ContentsCellContent(shown: nil, isEmphasized: false, size: .medium))
    private var shown: ContentsCellContent.Shown?
    private var size: NSTableView.RowSizeStyle = .medium

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(_ entry: ContentsEntry, size: NSTableView.RowSizeStyle) {
        shown = .row(entry)
        self.size = size
        refresh()
    }

    /// Shows a section's row: its title and symbol, and how many rows it holds.
    func show(_ section: ContentsSection, count: Int, size: NSTableView.RowSizeStyle) {
        shown = .section(section, count: count)
        self.size = size
        refresh()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { refresh() } }
    }

    private func refresh() {
        hosting.rootView = ContentsCellContent(shown: shown, isEmphasized: backgroundStyle == .emphasized, size: size)
    }
}

/// What a row's cell shows: the row, or a section's row, laid out as a source list's (its symbol in a
/// column of its own, in the accent color unless the row colors it), at the sidebar's size for its rows.
struct ContentsCellContent: View {
    /// A shape's row, or a section's, with how many rows it holds.
    enum Shown {
        case row(ContentsEntry)
        case section(ContentsSection, count: Int)
    }

    let shown: Shown?
    let isEmphasized: Bool
    let size: NSTableView.RowSizeStyle

    var body: some View {
        if let shown {
            content(shown)
                .labelStyle(ContentsRowLabelStyle())
                .font(.system(size: ContentsStyle.rowFontSize(size)))
                .environment(\.sidebarRowSize, ContentsStyle.sidebarRowSize(size))
                .environment(\.backgroundProminence, isEmphasized ? .increased : .standard)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func content(_ shown: Shown) -> some View {
        switch shown {
        case .row(let entry): ContentsRowView(entry: entry).equatable()
        case .section(let section, let count): ContentsSectionLabel(section: section, count: count)
        }
    }
}

/// A row's `Label` as a source list lays it out: its symbol in a column of its own, in the accent color
/// unless the row colors it, then its title.
struct ContentsRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: ContentsStyle.rowIconSpacing) {
            configuration.icon
                .foregroundStyle(.tint)
                .frame(width: ContentsStyle.rowIconWidth)
            configuration.title
        }
    }
}
