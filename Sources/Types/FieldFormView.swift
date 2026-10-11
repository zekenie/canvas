import AppKit
import Canvas
import Foundation
import TextEditing

// The form a card and the panel hold: one AppKit view that draws a `FieldSheet` and owns one text editor,
// which it moves over the cell with the caret. Every key of rows-and-cards is a text command AppKit already
// hands over (`FieldFormKeys.swift`), the writes are `FieldFormWrites.swift`'s, the drawing and the hit
// testing `FieldGridView.swift`'s. What a file does not hold (a blank line, half a pair) is a `FieldDraft`
// here, for each list or pairs level.

/// One level of what is shown: the root, and each row with more in it opened inside it (a card replaces the
/// sheet by the member's, with a line to go back; the panel nests, and has no levels).
struct FormLevel {
    var path: FieldPath
    var field: Resolved.Field
    var kind: FieldKind
    /// What the line above says it goes back to: `‹ shipping address`.
    var title: String
    /// The stop it was opened from, in the level above.
    var from: FieldStop?
    /// An either's branch the person picked.
    var branch: Int?
}

@MainActor
public final class FieldFormView: NSView {
    public enum Closing: Equatable { case escaped, returned, tabbed(forward: Bool) }

    public let editor: CanvasEditor
    public let shape: ShapeID
    let root: FieldFormRoot
    let mode: FieldFormMode
    public internal(set) var isReadOnly: Bool
    public let presentation: FieldFormContext.Presentation
    let cardKey: AnyHashable?
    let checkSource: (@MainActor (AnyShapeRecord) -> FieldCheck)?

    /// The top level asks to close (the card; the panel's form never does): Esc, Return on a blank last line,
    /// Tab off the last stop and ⇧Tab off the first.
    public var onClose: (@MainActor (Closing) -> Void)?
    /// What it holds changed size: the panel's host sets its height.
    public var onResize: (@MainActor () -> Void)?
    /// Where a menu goes; nil: `NSMenu.popUp`. Tests note the menu.
    public var menuPresenter: (@MainActor (NSMenu, CGPoint) -> Void)?
    /// The field it is for is gone from its type, or its kind has no card now.
    public var onGone: (@MainActor () -> Void)?
    /// The shape became read-only under it.
    public var onReadOnly: (@MainActor () -> Void)?

    public internal(set) var sheet = FieldSheet()
    public var depth: Int { levels.count - 1 }
    public internal(set) var focus: FieldStop?
    /// The one text editor, over the focused text cell.
    public let cellEditor = FieldCellEditor()

    var levels: [FormLevel]
    var foldFields: [Resolved.Field] = []
    var drafts: [FieldPath: FieldDraft] = [:]
    var localOpen: [FieldPath: Bool] = [:]
    let scroll = NSScrollView()
    let grid: FieldGridView
    let header: FieldHeaderView
    let cellClip = NSScrollView()
    var metrics = FormMetrics()
    /// The cell the editor is over, and the path it told the check it is typing in.
    var editorStop: FieldStop?
    var typingPath: FieldPath?
    var isLoadingEditor = false
    var isRebuilding = false
    /// A pair renamed to a name another has: marked until the caret moves; nothing was written.
    var conflict: FieldStop?
    var choiceStop: FieldStop?
    var preferredWidthKept: CGFloat?
    var nameColumnKept: CGFloat?
    var bookRevision = -1
    var checkRevision = -1

    public init(editor: CanvasEditor, shape: ShapeID, root: FieldFormRoot, mode: FieldFormMode, isReadOnly: Bool,
                presentation: FieldFormContext.Presentation, cardKey: AnyHashable? = nil,
                check: (@MainActor (AnyShapeRecord) -> FieldCheck)? = nil) {
        self.editor = editor
        self.shape = shape
        self.root = root
        self.mode = mode
        self.isReadOnly = isReadOnly
        self.presentation = presentation
        self.cardKey = cardKey
        self.checkSource = check
        switch root {
        case .field(let path, let field, let kind):
            levels = [FormLevel(path: path, field: field, kind: kind, title: FieldName.words(of: field.field))]
        case .fold(let fields):
            foldFields = fields
            let placeholder = Resolved.Field(field: ChainField(name: "", schema: .null), source: shape, introducedBy: shape)
            levels = [FormLevel(path: FieldPath(), field: placeholder, kind: .group, title: "")]
        }
        grid = FieldGridView()
        header = FieldHeaderView()
        super.init(frame: NSRect(x: 0, y: 0, width: TypesStyle.formMinWidth, height: 100))
        grid.form = self
        header.form = self
        wantsLayer = false
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        addSubview(header)
        addSubview(scroll)
        cellClip.drawsBackground = false
        cellClip.hasVerticalScroller = false
        cellClip.hasHorizontalScroller = false
        cellClip.borderType = .noBorder
        cellClip.documentView = cellEditor
        cellClip.isHidden = true
        grid.addSubview(cellClip)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(linesScrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        cellEditor.delegate = self
        cellEditor.onLeave = { [weak self] in self?.editorLeft() }
        if case .fold = root { levels[0].title = foldTitle() }
        editor.fieldCards?.follow(self)
        rebuild()
    }

    /// The lines scrolled: a table's names, which stay put above them, follow them sideways.
    @objc private func linesScrolled(_ notification: Notification) {
        header.needsDisplay = true
    }

    /// The panel's, and a test's: root `.field(context.path, context.field, context.kind)`, the key of
    /// `context.step` if it is `.card`.
    public convenience init(_ context: FieldFormContext, check: (@MainActor (AnyShapeRecord) -> FieldCheck)? = nil) {
        var key: AnyHashable?
        if case .card(let held) = context.step { key = held }
        self.init(editor: context.editor, shape: context.shape, root: .field(path: context.path, field: context.field, kind: context.kind), mode: context.mode,
                  isReadOnly: context.isReadOnly, presentation: context.presentation, cardKey: key, check: check)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // MARK: What it is made from

    var level: FormLevel { levels[levels.count - 1] }
    var isFold: Bool { if case .fold = root { true } else { false } }
    var font: NSFont { presentation == .card ? TypesStyle.formCardFont : TypesStyle.formPanelFont }
    var types: [ShapeID] {
        mode == .kinds ? [shape] : editor.document[shape]?[IsAProperty.self]?.map(\.shape) ?? []
    }

    /// What the check says, less the cell with the caret: it is not red while it is typed in.
    private func effectiveCheck() -> FieldCheck {
        guard let record = editor.document[shape] else { return .clean }
        let check = checkSource?(record) ?? editor.fieldChecks?.check(of: record) ?? .clean
        return typingPath.map(check.leaving(out:)) ?? check
    }

    private func makeSheet() -> FieldSheet {
        guard let book = editor.fieldBook, let writer = editor.fieldWriter else { return FieldSheet() }
        let values = writer.values(of: shape), check = effectiveCheck()
        let open = openNodes
        var made: FieldSheet
        if isFold, depth == 0 {
            made = FieldSheets.foldSheet(foldFields, values: values, check: check, book: book, types: types, mode: mode, isReadOnly: isReadOnly)
        } else {
            let at = level
            made = FieldSheets.sheet(path: at.path, field: at.field, kind: at.kind, values: values, check: check, book: book, types: types, mode: mode,
                                     isReadOnly: isReadOnly, presentation: presentation, drafts: drafts, open: open,
                                     back: depth > 0 ? FieldWords.back(levels[depth - 1].title) : nil, branch: at.branch)
        }
        if let held = conflict, made.lines.indices.contains(held.line), made.lines[held.line].cells.indices.contains(held.column) {
            made.lines[held.line].cells[held.column].mark = .wrong
        }
        return made
    }

    /// The panel's open nodes, kept for the session by shape and path (`FieldCards.panelOpen`).
    var openNodes: [FieldPath: Bool] {
        get { editor.fieldCards?.panelOpen[shape] ?? localOpen }
        set {
            if let cards = editor.fieldCards { cards.panelOpen[shape] = newValue } else { localOpen = newValue }
        }
    }

    /// `+12 more`, or `from Person` when one type brought every row: what the line back from inside it says.
    private func foldTitle() -> String {
        if let first = foldFields.first, foldFields.allSatisfy({ $0.introducedBy == first.introducedBy }) {
            return FieldWords.from(editor.types?.name(of: first.introducedBy) ?? TypesStyle.untitledType)
        }
        return FieldWords.more(foldFields.count)
    }

    // MARK: Reloading

    /// Asks `FieldSheets` again for the level shown and draws it; the editor keeps its text unless its own
    /// cell's stored value changed under it.
    public func reload() {
        guard editor.document[shape] != nil, revalidate() else { return }
        reconcileDrafts()
        rebuild()
    }

    /// The panel's host: what it hands changed.
    public func update(_ context: FieldFormContext) {
        isReadOnly = context.isReadOnly
        levels[0].field = context.field
        levels[0].kind = context.kind
        reload()
    }

    /// A reload only if a type or the check moved since: what the service's turn-later pass asks.
    func reloadIfStale() {
        let book = editor.fieldBook?.revision ?? 0, checks = editor.fieldChecks?.revision ?? 0
        guard book != bookRevision || checks != checkRevision else { return }
        reload()
    }

    /// The field a level shows is still the type's, with a kind that has a form; else the levels above it, else
    /// gone (`onGone`, and false: there is nothing to show).
    private func revalidate() -> Bool {
        guard let book = editor.fieldBook else { return true }
        if !isReadOnly, editor.isReadOnly(shape), mode == .values {
            isReadOnly = true
            onReadOnly?()
        }
        if isFold {
            let fresh = book.fields(types: types)
            let kept = foldFields.compactMap { fresh.field(named: $0.field.name) }
            if kept.isEmpty { onGone?() }
            foldFields = kept
        }
        let starts = isFold ? 1 : 0
        var keep = starts
        for place in starts..<levels.count {
            var held = levels[place]
            if mode == .kinds || isFold && place == 0 { keep = place + 1; continue }
            guard let field = resolve(held.path, book: book) else { break }
            held.field = field
            held.kind = book.kind(of: field)
            levels[place] = held
            keep = place + 1
        }
        if keep == 0 {
            onGone?()
            return false
        }
        if keep < levels.count {
            levels.removeSubrange(keep...)
            focus = levels.last?.from
        }
        if !isFold, !hasForm(levels[0].kind) { onGone?() }
        return true
    }

    /// The field a path names at a level, through the root field's own path.
    private func resolve(_ path: FieldPath, book: FieldBook) -> Resolved.Field? {
        book.field(at: path, types: types)
    }

    private func hasForm(_ kind: FieldKind) -> Bool {
        if presentation == .panel { return kind.hasMore || kind == .other }
        return mode == .kinds ? kind.opensOnType : kind.hasMore && kind != .other
    }

    /// Drafts follow what is stored: a list whose count differs is all stored again, pairs lose a gone key.
    private func reconcileDrafts() {
        guard let writer = editor.fieldWriter else { return }
        let values = writer.values(of: shape)
        for path in Array(drafts.keys) {
            drafts[path]?.reconcile(with: values.value(at: path))
        }
    }

    func rebuild() {
        sheet = makeSheet()
        clearSizes()
        bookRevision = editor.fieldBook?.revision ?? 0
        checkRevision = editor.fieldChecks?.revision ?? 0
        if let held = focus, !sheet.stops.contains(held) { focus = nearestStop(to: held) }
        metrics = computeMetrics(width: bounds.width > 0 ? bounds.width : preferredWidth())
        needsLayout = true
        layoutSubtreeIfNeeded()
        let typing = typingPath
        isRebuilding = true
        syncEditor()
        isRebuilding = false
        if typingPath != typing { refreshMarks() }
        grid.needsDisplay = true
        header.needsDisplay = true
        onResize?()
    }

    /// Where a stop that is gone left the keyboard: its line's other stop, else the nearest line before it.
    private func nearestStop(to stop: FieldStop) -> FieldStop? {
        if let same = sheet.stops.first(where: { $0.line == stop.line }) { return same }
        return sheet.stops.last { $0.line <= stop.line } ?? sheet.stops.first
    }

    // MARK: Cells

    func cell(at stop: FieldStop) -> FieldCell? {
        guard sheet.lines.indices.contains(stop.line) else { return nil }
        let cells = sheet.lines[stop.line].cells
        return cells.indices.contains(stop.column) ? cells[stop.column] : stop.column == -1 ? cells.first : nil
    }

    func line(at stop: FieldStop) -> FieldLine? {
        sheet.lines.indices.contains(stop.line) ? sheet.lines[stop.line] : nil
    }

    func isTypedControl(_ control: FieldCell.Control) -> Bool {
        switch control {
        case .text, .oneOf: true
        default: false
        }
    }

    /// What the stored value of a text cell is for the text in the editor.
    func typedValue(_ text: String, for cell: FieldCell) -> JSONValue? {
        switch cell.control {
        case .text(let kind): FieldText.value(from: text, as: kind)
        case .oneOf(let kinds): FieldText.value(from: text, asOneOf: kinds)
        default: nil
        }
    }

    // MARK: The editor

    /// Puts the editor over the focused text cell, or takes it away.
    func syncEditor() {
        guard let stop = focus, let cell = cell(at: stop), isTypedControl(cell.control), cell.isEditable, !isReadOnly else {
            hideEditor()
            return
        }
        let rect = grid.cellRect(line: stop.line, column: stop.column)
        cellClip.frame = rect
        let inset = max((rect.height - font.boundingRectForFont.height) / 2, 0)
        cellEditor.textContainerInset = NSSize(width: 0, height: inset)
        cellEditor.minSize = rect.size
        if editorStop != stop || cellClip.isHidden {
            loadEditor(cell, at: stop)
            return
        }
        // Its text stays, unless its own cell's stored value was written by something else.
        let typed = typedValue(cellEditor.string, for: cell)
        if typed != cell.value, cellEditor.string != cell.shown, conflict != stop { setEditorText(cell.shown) }
        if cellEditor.frame.height != rect.height { cellEditor.frame.size.height = rect.height }
    }

    private func setEditorText(_ text: String) {
        isLoadingEditor = true
        cellEditor.string = text
        cellEditor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        isLoadingEditor = false
    }

    private func loadEditor(_ cell: FieldCell, at stop: FieldStop) {
        editorStop = stop
        isLoadingEditor = true
        cellEditor.font = font
        cellEditor.textColor = TypesStyle.formValueInk
        cellEditor.typingAttributes = [.font: font, .foregroundColor: TypesStyle.formValueInk]
        cellEditor.string = cell.shown
        cellEditor.setSelectedRange(NSRange(location: 0, length: (cell.shown as NSString).length))
        cellEditor.frame = NSRect(origin: .zero, size: cellClip.frame.size)
        cellClip.isHidden = false
        isLoadingEditor = false
        // The editor goes from cell to cell, and the window clears a text's undo only when the keyboard changes hands.
        cellEditor.undoManager?.removeAllActions()
        typingPath = cell.path
        editor.fieldChecks?.typing = (shape, cell.path)
        if let window, window.firstResponder !== cellEditor { window.makeFirstResponder(cellEditor) }
        if !isRebuilding { refreshMarks() }
    }

    private func hideEditor() {
        let wasEditing = editorStop != nil
        editorStop = nil
        if window?.firstResponder === cellEditor { window?.makeFirstResponder(self) }
        cellClip.isHidden = true
        if wasEditing { stopTyping() }
    }

    /// The caret left the editor, for another stop or out of the form.
    private func editorLeft() {
        stopTyping()
    }

    /// Tells the check the caret is not in a cell any more, if this form told it that it was, and shows the
    /// cell as the check marks it.
    func stopTyping() {
        guard let path = typingPath else { return }
        typingPath = nil
        if let checks = editor.fieldChecks, let typing = checks.typing, typing.shape == shape, typing.path == path { checks.typing = nil }
        if !isRebuilding { refreshMarks() }
    }

    /// The check's marks again, with no layout: the cell with the caret came or went.
    func refreshMarks() {
        sheet = makeSheet()
        grid.needsDisplay = true
        needsDisplay = true
    }

    /// The form is going: the check is told, the editor stands down.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, window != nil {
            editorStop = nil
            stopTyping()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if let stop = focus, let cell = cell(at: stop), isTypedControl(cell.control) { editorStop = nil; syncEditor() }
        else if focus != nil { window?.makeFirstResponder(self) }
    }

    // MARK: Focus

    /// The keyboard goes to the first stop: a text cell gets the caret with its text selected.
    public func focusFirst() {
        focus(sheet.stops.first)
    }

    /// Moves the keyboard to a stop (nil: to the form itself, no stop).
    public func focus(_ stop: FieldStop?) {
        if let stop, !sheet.stops.contains(stop) { return }
        focus = stop
        syncEditor()
        if stop != nil, editorStop == nil, let window, window.firstResponder !== self { window.makeFirstResponder(self) }
        if let stop { scrollToVisible(stop) }
        grid.needsDisplay = true
        needsDisplay = true
    }

    /// Scrolls the grid so the stop is in view, under what stays put.
    func scrollToVisible(_ stop: FieldStop) {
        guard stop.line >= 0, sheet.lines.indices.contains(stop.line) else { return }
        grid.scrollToVisible(grid.lineRect(stop.line))
    }

    /// Where a stop is, in the form's coordinates (the grid's, scrolled and offset).
    public func rect(of stop: FieldStop) -> CGRect {
        if stop.line < 0 { return header.branchRect(stop.column).offsetBy(dx: header.frame.minX, dy: header.frame.minY) }
        let inGrid = stop.column == -1 ? grid.lineRect(stop.line) : grid.cellRect(line: stop.line, column: stop.column)
        return grid.convert(inGrid, to: self)
    }
}
