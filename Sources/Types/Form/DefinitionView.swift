import AppKit
import Canvas
import Foundation
import Mentions
import TextEditing
import Titles

// The card that defines a relationship type, hung from its pill (`DefinitionCards`): its name, its fields (a name and, at the
// right, a kind), `add field`, a hairline, and one line for each end (the end type's chip, the row's name, Needed, Only one). It
// is the form's look and keys over the form's one cell editor (`FieldCellEditor`): Tab and ⇧Tab move, Return goes on, Esc ends,
// ↑ and ↓ go by lines, and a stop that is no text (a kind, a check) has the keyboard itself. It writes nothing of its own: fields
// and options through the one writer (`FieldDefiner`, a step each), the name as the title (one coalesced step), a row's name as
// the end arrow's words (one coalesced step), and the rules through `setEndRule`. It reads the file again after every commit
// and draws what differs (`reload`).

extension TypesStyle {
    /// The card's width, and the room the kind takes at the right of a field's line, and the indent of a choice's options.
    static let definitionWidth: CGFloat = 340
    static let definitionKindWidth: CGFloat = 92
    static let definitionIndent: CGFloat = 16
    /// The empty line that adds a field.
    static let addFieldWords = "add field"
    /// The undo steps the card names itself.
    public static let nameRow = "Name Row"
    /// The hairline's line, and the room between a check's box and its words.
    static let definitionRuleHeight: CGFloat = 9
    static let definitionCheckGap: CGFloat = 5
    static let definitionCheckFont = NSFont.systemFont(ofSize: 11)
}

/// What a coalesced step of the card is: the title, or a row's name.
struct DefinitionStepKey: Hashable {
    var shape: ShapeID
    var row: Bool
}

@MainActor
public final class DefinitionView: NSView {
    public enum Closing: Equatable { case escaped, returned, tabbed(forward: Bool) }

    public let editor: CanvasEditor
    public let hub: ShapeID
    /// The type, or its board, can't change: nothing has the caret and a try shakes the type.
    public internal(set) var isReadOnly: Bool

    /// The card asks to be taken down: Esc, Return on the blank `add field`, Tab off the last stop and ⇧Tab off the first.
    public var onClose: (@MainActor (Closing) -> Void)?
    /// The card wants another height.
    public var onResize: (@MainActor () -> Void)?
    /// The type is no relationship type now (or is gone).
    public var onGone: (@MainActor () -> Void)?

    var model: DefinitionModel
    var lines: [DefinitionLine] = []
    var placed: [(line: DefinitionLine, rect: CGRect)] = []
    public internal(set) var focus: DefinitionStop?
    /// The field whose kinds are listed, and the one in the list that Return takes.
    public internal(set) var listing: String?
    public internal(set) var highlight = 0
    /// The field just added by `add field`: picking its kind goes on to the next line.
    var fresh: String?
    /// The stop a key brought the keyboard in at from outside the card (Tab in the pill's name, at its first line past the name): ⇧Tab there goes
    /// back out as the key came in (P4's exact way back). Any other move of the keyboard forgets it.
    public internal(set) var entry: DefinitionStop?
    /// The card was entered by the walk from the pill's name or back from the shape after it, so the name is the pill's own
    /// stop, edited under it, not the card's: the walk goes between the pill's name and the card's first line, and the card's
    /// Name stop is passed in both directions (Open Fields starts at it, and walks it).
    public internal(set) var passesTitle = false

    /// The one text editor, over the focused text stop.
    public let cellEditor = FieldCellEditor()
    let cellClip = NSScrollView()
    let scroll = NSScrollView()
    let content = DefinitionContent()
    var editorStop: DefinitionStop?
    /// The elements VoiceOver was given for the stops, kept so each is the same object from one query to the next.
    var stopElements: [DefinitionStop: CardStopElement] = [:]
    /// A key is being handled: a stop that goes is replaced by the one the key chose, not by the fallback.
    var isMoving = false
    var isLoadingEditor = false
    var chipColumn: CGFloat = 0

    init(editor: CanvasEditor, hub: ShapeID, model: DefinitionModel) {
        self.editor = editor
        self.hub = hub
        self.model = model
        isReadOnly = editor.isReadOnly(inFile: hub)
        super.init(frame: NSRect(x: 0, y: 0, width: TypesStyle.definitionWidth, height: 100))
        content.owner = self
        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        addSubview(scroll)
        cellClip.drawsBackground = false
        cellClip.hasVerticalScroller = false
        cellClip.hasHorizontalScroller = false
        cellClip.borderType = .noBorder
        cellClip.documentView = cellEditor
        cellClip.isHidden = true
        content.addSubview(cellClip)
        cellEditor.delegate = self
        cellEditor.onCommit = { [weak self] in self?.finish() }
        relayout()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // MARK: What is shown

    /// The stops, in the order Tab goes.
    public var stops: [DefinitionStop] { model.lines(listing: listing).flatMap { $0.stops(in: model) } }

    /// The title as the card holds it, and the fields, as written.
    public var title: String { model.title }
    public var fields: [DefinedField] { model.fields }
    /// The end lines, from ends first.
    public var ends: [DefinitionEnd] { model.ends }
    /// The kinds listed under a field's line, while one is.
    public var listedKinds: [DefinedKind] { listing == nil ? [] : DefinedKind.allCases }

    var font: NSFont { TypesStyle.formCardFont }
    var titleFont: NSFont { NSFont.systemFont(ofSize: 13, weight: .semibold) }

    func font(for stop: DefinitionStop) -> NSFont { stop == .title ? titleFont : font }

    // MARK: Layout

    var width: CGFloat { TypesStyle.definitionWidth }
    var contentHeight: CGFloat { (placed.last?.rect.maxY ?? 0) + TypesStyle.formPadY }

    /// The size the card wants, in view points, no larger than `room`.
    public func fittingSize(room: CGSize) -> CGSize {
        CGSize(width: min(width, room.width), height: max(44, min(contentHeight, TypesStyle.formMaxHeight, room.height)))
    }

    func relayout() {
        lines = model.lines(listing: listing)
        chipColumn = model.ends.map { chipWidth($0.type) }.max() ?? 0
        var y = TypesStyle.formPadY
        placed = lines.map { line in
            let height = line == .rule ? TypesStyle.definitionRuleHeight : TypesStyle.formRowHeight
            defer { y += height }
            return (line, CGRect(x: 0, y: y, width: width, height: height))
        }
        let height = contentHeight
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let shown = min(height, TypesStyle.formMaxHeight)
        if frame.size != CGSize(width: width, height: shown) { setFrameSize(NSSize(width: width, height: shown)) }
        scroll.frame = bounds
        content.needsDisplay = true
        syncEditor()
    }

    public override func layout() {
        super.layout()
        scroll.frame = bounds
    }

    private func checkWidth(_ label: String) -> CGFloat {
        TypesStyle.formBoxSize + TypesStyle.definitionCheckGap + textWidth(label, in: TypesStyle.definitionCheckFont)
    }

    func textWidth(_ text: String, in font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    func chipWidth(_ type: ShapeID) -> CGFloat {
        textWidth(chipName(type).text, in: TypesStyle.formChipFont) + 2 * TypesStyle.formChipPad
    }

    func chipName(_ type: ShapeID) -> (text: String, isGone: Bool) {
        guard let index = editor.types else { return (TypesStyle.deletedType, true) }
        let name = index.name(of: TypeLink(type))
        if case .missing = name { return (TypesStyle.menuName(name), true) }
        return (TypesStyle.menuName(name), false)
    }

    /// The row of a line, in the content's coordinates.
    func rect(of line: DefinitionLine) -> CGRect? { placed.first { $0.line == line }?.rect }

    /// Where a stop is, in the content's coordinates; nil for a stop that is not there.
    public func rect(of stop: DefinitionStop) -> CGRect? {
        let pad = TypesStyle.formPadX
        for (line, row) in placed where line.stops(in: model).contains(stop) {
            switch stop {
            case .title, .addField:
                return CGRect(x: pad, y: row.minY, width: width - 2 * pad, height: row.height)
            case .fieldName:
                return CGRect(x: pad, y: row.minY, width: width - 2 * pad - TypesStyle.definitionKindWidth - TypesStyle.formGap, height: row.height)
            case .fieldKind:
                return CGRect(x: width - pad - TypesStyle.definitionKindWidth, y: row.minY, width: TypesStyle.definitionKindWidth, height: row.height)
            case .option, .newOption:
                let x = pad + TypesStyle.definitionIndent
                return CGRect(x: x, y: row.minY, width: width - pad - x, height: row.height)
            case .endName:
                let x = pad + chipColumn + TypesStyle.formGap
                let end = neededRect(row).minX - TypesStyle.formGap
                return CGRect(x: x, y: row.minY, width: max(20, end - x), height: row.height)
            case .needed: return neededRect(row)
            case .onlyOne: return onlyOneRect(row)
            }
        }
        return nil
    }

    private func onlyOneRect(_ row: CGRect) -> CGRect {
        let w = checkWidth(TypesStyle.onlyOneChoice)
        return CGRect(x: width - TypesStyle.formPadX - w, y: row.minY, width: w, height: row.height)
    }

    private func neededRect(_ row: CGRect) -> CGRect {
        let w = checkWidth(TypesStyle.neededChoice)
        return CGRect(x: onlyOneRect(row).minX - TypesStyle.formGap - w, y: row.minY, width: w, height: row.height)
    }

    /// The list of kinds, as one box at the right of the field's line.
    public func listRect(at kind: Int, of field: Int) -> CGRect? {
        guard let row = rect(of: .kindChoice(field, kind)) else { return nil }
        let w: CGFloat = 112
        return CGRect(x: width - TypesStyle.formPadX - w, y: row.minY, width: w, height: row.height)
    }

    // MARK: Reading the file again

    /// Reads the type again and shows what differs. The card tells its owner when the type is no relationship type.
    public func reload() {
        guard let new = DefinitionModel.read(hub, in: editor) else { return onGone?() ?? () }
        isReadOnly = editor.isReadOnly(inFile: hub)
        guard new != model else { return }
        let old = model
        model = new
        if let listing, !model.fields.contains(where: { $0.key == listing }) { self.listing = nil }
        if let fresh, !model.fields.contains(where: { $0.key == fresh }) { self.fresh = nil }
        if let focus, !stops.contains(focus) { self.focus = nil }
        let before = height
        relayout()
        // The caret's cell was written by another surface: it shows that.
        if let stop = editorStop, !isLoadingEditor, let was = old.text(of: stop), let now = model.text(of: stop), was != now,
           stop == .title ? TitleProperty.folded(cellEditor.string) ?? "" != now : cellEditor.string != now {
            setEditorText(now)
        }
        if focus == nil, !isMoving { self.focus(fallbackStop()) }
        if height != before { onResize?() }
    }

    private var height: CGFloat { frame.height }

    /// Where the keyboard goes when its stop has gone.
    func fallbackStop() -> DefinitionStop? { stops.contains(.addField) ? .addField : stops.first }

    // MARK: Focus

    /// The keyboard goes to the stop: a text one has the caret with its text selected. Whatever was typed in the stop it leaves is
    /// written first. A read-only card takes any stop and draws its mark, with no caret (the card has the keyboard itself).
    public func focus(_ stop: DefinitionStop?) {
        let old = focus
        if stop != entry { entry = nil }
        if let old = editorStop, old != stop { commit(old) }
        var stop = stop
        if let held = stop, !stops.contains(held) { stop = fallbackStop() }
        focus = stop
        if let listing, focus != .fieldKind(listing) { closeList() }
        syncEditor()
        if let window {
            if editorStop != nil, window.firstResponder !== cellEditor { window.makeFirstResponder(cellEditor) }
            else if editorStop == nil, window.firstResponder !== self { window.makeFirstResponder(self) }
        }
        if let stop, let rect = rect(of: stop) { content.scrollToVisible(rect) }
        content.needsDisplay = true
        announceFocus(from: old)
    }

    /// The first stop: the card opens at the name, or at `add field`.
    public func focusFirst() { focus(stops.first) }

    /// The keyboard comes in at `stop` by a key from outside the card: ⇧Tab there goes back out (`entry`).
    public func enter(at stop: DefinitionStop?) {
        focus(stop)
        entry = isReadOnly ? nil : focus
    }

    /// Shows the editor over the focused text stop, or hides it.
    func syncEditor() {
        guard let stop = focus, stop.isText, !isReadOnly, let rect = rect(of: stop), let text = model.text(of: stop) else {
            hideEditor()
            return
        }
        cellClip.frame = rect
        let inset = max((rect.height - font(for: stop).boundingRectForFont.height) / 2, 0)
        cellEditor.textContainerInset = NSSize(width: 0, height: inset)
        cellEditor.minSize = rect.size
        if editorStop != stop || cellClip.isHidden {
            editorStop = stop
            isLoadingEditor = true
            let face = font(for: stop)
            cellEditor.font = face
            cellEditor.textColor = TypesStyle.formValueInk
            cellEditor.insertionPointColor = TypesStyle.formValueInk
            cellEditor.typingAttributes = [.font: face, .foregroundColor: TypesStyle.formValueInk]
            cellEditor.string = text
            cellEditor.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
            cellEditor.frame = NSRect(origin: .zero, size: rect.size)
            cellClip.isHidden = false
            isLoadingEditor = false
            // The editor goes from cell to cell, and the window clears a text's undo only when the keyboard changes hands.
            cellEditor.undoManager?.removeAllActions()
            if let window, window.firstResponder !== cellEditor { window.makeFirstResponder(cellEditor) }
        } else if cellEditor.frame.height != rect.height {
            cellEditor.frame.size.height = rect.height
        }
    }

    func hideEditor() {
        editorStop = nil
        if window?.firstResponder === cellEditor { window?.makeFirstResponder(self) }
        cellClip.isHidden = true
    }

    func setEditorText(_ text: String) {
        isLoadingEditor = true
        cellEditor.string = text
        cellEditor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        isLoadingEditor = false
        content.needsDisplay = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let stop = focus else { return }
        editorStop = nil
        syncEditor()
        if !stop.isText { window?.makeFirstResponder(self) }
    }

    // MARK: Lists

    func openList(for key: String) {
        guard !isReadOnly, let field = model.fields.first(where: { $0.key == key }), field.kind != nil else { return }
        listing = key
        highlight = field.kind.flatMap { DefinedKind.allCases.firstIndex(of: $0) } ?? 0
        let before = height
        relayout()
        if height != before { onResize?() }
    }

    func closeList() {
        guard listing != nil else { return }
        listing = nil
        let before = height
        relayout()
        if height != before { onResize?() }
    }
}

/// The view the lines are drawn in, inside the card's scroll view: it draws and hears the mouse for the card.
@MainActor
final class DefinitionContent: NSView {
    weak var owner: DefinitionView?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawLines(in: dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.click(at: convert(event.locationInWindow, from: nil))
    }
}
