import AppKit
import Canvas
import Geometry
import Mentions
import Selection
import TextEditing

extension PluginID {
    public static let connectPicker: PluginID = "connect-picker"
}

/// ⌘L's picker, as a plugin: one shape selected and ⌘L opens a line under it that lists the shapes it can be connected to, in the
/// file, and Itself; a list without it keeps ⌘L's loop. A plugin value of its own, after `PortsPlugin`, which declares ⌘L, and
/// `MentionsPlugin`, whose catalog it ranks.
public struct ConnectPickerPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .connectPicker }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ConnectPickerHost(editor: $0) }
        // Never acting on a shape it wasn't opened for.
        registrar.selectionChanged { editor, _, _ in editor.connectPicker?.close() }
    }
}

/// What the picker is as a card, to the core.
struct ConnectPickerCard: Hashable, Sendable {}

/// The picker (`editor.connectPicker`, a service; nil without `ConnectPickerPlugin`): a core card about no shape's content
/// (`showsZoomedOut`), so it works among skeletons too, hung under the shape it was opened on, out to its outline, holding a
/// one-line field with a faint `→` lead and a caret list under it. It closes as anything else happens: a pick (before the arrow is
/// made, so the canvas has the keyboard and a release the connection offers is the canvas's), Escape and ⌘. (the canvas has the
/// keyboard back, the selection as it was), the keyboard leaving its field, the selection changing, and every way a card closes
/// (a press elsewhere, another board, an undo, editing, another card shown). It keeps nothing per shape.
@MainActor
public final class ConnectPickerHost {
    private unowned let editor: CanvasEditor
    private var shown: Shown?

    private struct Shown {
        let picker: ConnectPicker
        let field: ConnectPickerTextView
        /// Told once a pick is done, whether it made a connection.
        let didPick: (@MainActor (Bool) -> Void)?
    }

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// Whether it shows.
    public var isOpen: Bool { shown != nil }
    /// Whether it shows for `shape` or a row of it: ⌘L pressed again in its field does nothing, so what was typed and the way back to
    /// the row it came from stay.
    public func isOpen(on shape: ShapeID) -> Bool { shown?.picker.sourceEnd.shape == shape }
    /// Its field, while it shows.
    public var field: EditingTextView? { shown?.field }
    /// What it lists, while it shows.
    public var picker: ConnectPicker? { shown?.picker }
    /// What a shape being edited in rows answers ⌘L's command with (Connect, from its menu item as from its key): opens the picker on the
    /// row with the caret, true, or false for a shape with none. Set by the editing view that has rows (LineRows), so a click and the
    /// key mean the same.
    public var connectsEditedRow: (@MainActor (ShapeID) -> Bool)?
    /// Why it closed last (`.asked` for its own closing: a pick, Escape).
    public private(set) var lastClosing: CanvasCardClosing?
    /// Whether a pick is under way: it has closed the picker and has not yet made its connection. What takes the keyboard back as
    /// the picker closes can tell a pick from Escape by it.
    public private(set) var isPicking = false

    /// Whether ⌘L can open it on this shape: something to pick for it.
    public func canOpen(on shape: ShapeID) -> Bool { ConnectPicker.reach(of: shape, in: editor) != nil }

    /// Opens it on `shape`, under it, brought into view first if it isn't (as a nudge does, so what the key acts on shows), in
    /// place of another card, which closes `.replaced`. A shape it has nothing to pick for shakes. Opened on the shape it already
    /// shows for, it does nothing (⌘L pressed in its field: the field keeps the keyboard and what's typed); on another it is taken
    /// down first, so its field and its list go with it.
    public func open(on shape: ShapeID) {
        open(on: ConnectEnd(shape))
    }

    /// Opens it on a shape or a row of one (a row being edited: ⌘L in its line), as `open(on:)` does a shape, hung under the row,
    /// listing rows too (`ConnectPicker`). `returningKeyboardTo` is what has the keyboard back as it closes (the row's line, so the
    /// shape stays edited), else what the core gives it back to. `didPick` is told once a pick of its rows is done, with whether it made
    /// a connection (a pick the connector refuses makes none); Escape and every other way it closes tell it nothing.
    public func open(on source: ConnectEnd, returningKeyboardTo: NSResponder? = nil, didPick: (@MainActor (Bool) -> Void)? = nil) {
        let shape = source.shape
        if let shown {
            if shown.picker.sourceEnd == source { return }
            close()
        }
        guard let picker = ConnectPicker(editor: editor, source: source) else {
            editor.refuseChanges(to: [shape])
            return
        }
        editor.revealIfOffscreen([shape])
        guard let anchor = anchor(of: source) else { return }
        let field = ConnectPickerTextView(picker: picker)
        // Each acts only while its own field is the picker's: a field being taken down is not heard as the one that replaced it.
        field.onEscape = { [weak self, weak field] in self?.close(ifFieldIs: field) }
        field.onLeave = { [weak self, weak field] in self?.close(ifFieldIs: field) }
        field.pick = { [weak self, weak field] row in
            guard let self, self.shown?.field === field else { return }
            self.pick(row: row)
        }
        field.closeByList = { [weak self, weak field] in self?.close(ifFieldIs: field) }
        // "Connect from order_items", "Connect from customer_id in orders".
        let name = (source.part != nil ? editor.accessibleName(of: source.address) : nil) ?? editor.accessibleDescription(of: shape)?.name ?? ""
        let view = ConnectPickerView(field: field)
        let card = CanvasCard(id: ConnectPickerCard(), about: shape, anchor: anchor, view: view, firstResponder: field,
                              returnsKeyboardTo: returningKeyboardTo, showsZoomedOut: true,
                              accessibilityLabel: ConnectionsStyle.cardLabel(name),
                              size: { room in CGSize(width: min(ConnectionsStyle.pickerFieldWidth, room.width), height: ConnectionsStyle.pickerFieldHeight) },
                              didClose: { [weak self, weak field] reason in self?.didClose(field, reason) })
        shown = Shown(picker: picker, field: field, didPick: didPick)
        guard editor.showCard(card) else {
            shown = nil
            return
        }
    }

    /// Takes it down, if it shows: the canvas has the keyboard back, the selection as it was.
    public func close() {
        guard shown != nil else { return }
        if editor.card?.id == AnyHashable(ConnectPickerCard()) {
            editor.closeCard()
        } else {
            shown?.field.detachList()
            shown = nil
        }
    }

    private func close(ifFieldIs field: ConnectPickerTextView?) {
        guard let field, field === shown?.field else { return }
        close()
    }

    private func didClose(_ field: ConnectPickerTextView?, _ reason: CanvasCardClosing) {
        guard let field else { return }
        // Its list goes with it whichever picker is the current one, and why it closed is said either way.
        field.detachList()
        lastClosing = reason
        guard field === shown?.field else { return }
        shown = nil
    }

    /// A pick of a row, as Return on it is: it closes first, so the connection is made from the canvas as from a key, then what the pick means is done
    /// (`ConnectPlan`), in one step, and said.
    public func pick(row: Int) {
        guard let shown, let target = shown.picker.pickEnd(row: row) else { return }
        let source = shown.picker.sourceEnd, didPick = shown.didPick
        isPicking = true
        close()
        let made = commit(from: source, to: target)
        isPicking = false
        didPick?(made)
    }

    /// What a pick of `target` on `source` is: its plan (the kind's, else a plain connection) made, a person's pick being allowed to
    /// make a private far shape public in its step.
    @discardableResult
    func commit(from source: ConnectEnd, to target: ConnectEnd) -> Bool {
        switch editor.connectPlan(from: source, to: target) {
        case .refused:
            editor.refuseChanges(to: [source.shape])
            return false
        case .plan(let plan):
            let before = editor.revision
            if editor.connect(plan.from, to: plan.to, plan: plan, fulfil: true) != nil, editor.revision != before {
                editor.announce(plan.step)
                return true
            }
            return false
        }
    }

    // MARK: Where it hangs

    /// The shape's bounds out to the outline drawn round it (none zoomed out, where outlines stand off nothing), so it sits clear of
    /// the selection's line; a row's own rect, for a picker opened on a row.
    private func anchor(of source: ConnectEnd) -> CGRect? {
        if let part = source.part, let row = editor.shapeContext.geometry(of: source.shape)?.parts.frame(part) { return row.rect }
        guard let bounds = editor.shapeContext.bounds(of: [source.shape]) else { return nil }
        let zoom = editor.cameraTarget.zoom
        let gap = editor.drawsSkeletons || zoom <= 0 ? 0 : editor.outlineGap / zoom
        return bounds.insetBy(dx: -gap, dy: -gap)
    }
}

extension ConnectPickerHost: EditorService {
    /// A commit changed what it lists or moved the shape: the list is made again for what's typed, the highlight staying on its shape,
    /// and it follows the shape.
    public func documentDidSettle(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard let shown, editor.card?.id == AnyHashable(ConnectPickerCard()) else { return }
        shown.picker.relistAfterCommit(shown.field.string)
        if let anchor = anchor(of: shown.picker.sourceEnd) { editor.moveCard(to: anchor) }
    }
}

extension CanvasEditor {
    /// ⌘L's picker; nil without `ConnectPickerPlugin`.
    public var connectPicker: ConnectPickerHost? { service(ConnectPickerHost.self) }
}

// MARK: The field

/// The picker's field: one line of the app's text view, its list the picker's, in a `CaretListWindow` under it. Return and Tab pick
/// (the list's keys, held while it's open) and are never text; ⇧Tab moves the highlight up; Escape and ⌘. close it, and the canvas
/// has the keyboard. It types a name, not prose: one line, every substitution off, its spelling unchecked.
@MainActor
public final class ConnectPickerTextView: EditingTextView {
    private(set) var picker: ConnectPicker!
    var listWindow: CaretListWindow?
    /// Escape, or ⌘.: the person closed the picker.
    var onEscape: (@MainActor () -> Void)?
    /// A row picked (Return, Tab, a click).
    var pick: (@MainActor (Int) -> Void)?
    /// The list asked to close (its anchor left the view, or its window stopped being key).
    var closeByList: (@MainActor () -> Void)?

    // `init(frame:)` makes the text system and goes through `init(frame:textContainer:)`, which AppKit asks of this class: it's
    // the one that sets the field up.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init(picker: ConnectPicker) {
        self.init(frame: .zero)
        self.picker = picker
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        font = ConnectionsStyle.pickerFont
        textColor = .labelColor
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        textContainer?.maximumNumberOfLines = 1
        textContainer?.lineBreakMode = .byClipping
        let font = ConnectionsStyle.pickerFont
        let line = font.ascender - font.descender + font.leading
        textContainerInset = NSSize(width: 0, height: max(0, ((ConnectionsStyle.pickerFieldHeight - line) / 2).rounded(.down)))
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        CaretListSubstitutions.off.apply(to: self)
        tabBehavior = .host
        setAccessibilityLabel(ConnectionsStyle.fieldLabel)
    }

    override public var caretListWindow: CaretListWindow? { listWindow }

    /// The list stays open whatever is pressed.
    override public var closesListOnTab: Bool { false }

    // MARK: The list

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attachList() }
    }

    /// Makes the list's window once the field is in its window: under the field, following it.
    private func attachList() {
        guard listWindow == nil else { return }
        let window = CaretListWindow(picker.list, accessibilityLabel: ConnectionsStyle.listLabel, over: self,
                                     anchorRect: { [weak self] in self?.screenRect },
                                     pick: { [weak self] row in self?.pick?(row) },
                                     close: { [weak self] in self?.closeByList?() })
        listWindow = window
        picker.list.onChange = { [weak window] in window?.listDidChange() }
        window.listDidChange()
    }

    /// The list goes with the picker: nothing follows its changes.
    func detachList() {
        guard let window = listWindow else { return }
        listWindow = nil
        picker.list.onChange = nil
        window.dismiss()
    }

    /// The field, in screen coordinates: where the list goes under.
    private var screenRect: CGRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    // MARK: One line, and the list's keys

    override public func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape?()
            return
        }
        // The picker stays modal: ⇧Tab moves the highlight up, and Tab with nothing to pick does nothing.
        if selector == #selector(NSResponder.insertBacktab(_:)) {
            picker.list.moveHighlight(by: -1)
            return
        }
        if selector == #selector(NSResponder.insertTab(_:)), picker.list.highlightedItem == nil { return }
        super.doCommand(by: selector)
    }

    /// ⌘., sent up the responder chain as a command with no key.
    override public func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    // The query is one line: Return and Tab with nothing to pick, and a line break, insert nothing.
    override public func insertNewline(_ sender: Any?) {}
    override public func insertTab(_ sender: Any?) {}
    override public func insertBacktab(_ sender: Any?) {}
    override public func insertLineBreak(_ sender: Any?) {}
    override public func insertParagraphSeparator(_ sender: Any?) {}
    override public func insertNewlineIgnoringFieldEditor(_ sender: Any?) {}
    override public func insertTabIgnoringFieldEditor(_ sender: Any?) {}

    /// Text pasted in is one line: its line breaks and tabs are spaces. The list is made again for what's typed.
    override public func didChangeText() {
        if string.contains(where: { $0.isNewline || $0 == "\t" }) {
            let range = selectedRange()
            string = String(string.map { $0.isNewline || $0 == "\t" ? " " : $0 })
            setSelectedRange(range)
        }
        super.didChangeText()
        picker.setQuery(string)
    }
}

// MARK: The view

/// What the card shows: a faint `→` and the field after it.
@MainActor
final class ConnectPickerView: NSView {
    let field: NSView
    private let lead = NSTextField(labelWithString: ConnectionsStyle.lead)

    init(field: NSView) {
        self.field = field
        super.init(frame: CGRect(x: 0, y: 0, width: ConnectionsStyle.pickerFieldWidth, height: ConnectionsStyle.pickerFieldHeight))
        lead.font = ConnectionsStyle.pickerFont
        lead.textColor = .tertiaryLabelColor
        lead.setAccessibilityElement(false)
        addSubview(lead)
        addSubview(field)
        layoutParts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutParts()
    }

    private func layoutParts() {
        let inset = ConnectionsStyle.pickerInset
        let size = lead.intrinsicContentSize
        lead.frame = CGRect(x: inset, y: ((bounds.height - size.height) / 2).rounded(), width: ceil(size.width), height: ceil(size.height))
        let x = lead.frame.maxX + ConnectionsStyle.pickerLeadGap
        field.frame = CGRect(x: x, y: 0, width: max(0, bounds.width - x - inset), height: bounds.height)
    }
}
