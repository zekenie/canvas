import AppKit
import Canvas
import Selection
import TextEditing
import Titles

// The editing view of a kind whose content is its rows (a table, an enum): its stops are the title, typed in its pill
// (Titles' field), each row, and one waiting line, an empty line not yet a row. One line field is moved to the stop with
// the caret, so only that row is drawn as typed; the kind draws the rest, skipping the focused row and leaving the
// waiting line's room (`LineRowsLayout.focused`, `LineRowsLayout.waiting`, set while it's edited). A row's line is a draft until the
// caret leaves it, when it commits as one step the kind names ("Add Column", "Rename Column", "Delete Column"); ⌥↑ ⌥↓
// move a row, repeats one step; a pasted block is a row a line, one step. VoiceOver hears it as a group of rows.

/// A stop of a row-written shape's editing: its title, a row, or the waiting line.
public enum LineStop: Hashable, Sendable, CustomStringConvertible {
    case title
    case row(PartID)
    case waiting

    public var description: String {
        switch self {
        case .title: "title"
        case .row(let id): "row \(id)"
        case .waiting: "waiting"
        }
    }
}

/// A shape's title stop: the field its name is typed in, made from the title it has (Titles' `TitleField`).
@MainActor
public struct LineTitle {
    let make: @MainActor (String?) -> TitleField

    public init(_ make: @escaping @MainActor (String?) -> TitleField) { self.make = make }
}

/// Moves of one row, repeated, coalesced into one step.
struct LineMoveRun: Hashable {
    let shape: ShapeID
    let row: PartID
}

/// The editing view of a kind written as lines, as a host and a test read it, whatever its rows are.
@MainActor
public class LineRowsView: NSView {
    /// The line rows are typed in, moved to the stop with the caret.
    public let field = LineField()
    /// The title's field, where the kind's title is typed in its pill.
    public internal(set) var titleField: TitleField?
    /// Where the caret is.
    public internal(set) var focus: LineStop = .waiting
    /// The clip the field slides in.
    let clip = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        clip.clipsToBounds = true
        clip.addSubview(field)
        addSubview(clip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// Every stop, in order: the title, the rows with the waiting line among them.
    public var stops: [LineStop] { [] }

    /// The responder of the stop with the caret.
    public var focusedResponder: NSResponder { focus == .title ? (titleField?.field ?? field) : field }

    /// Goes to a stop as a key would, committing the line it leaves.
    public func go(to stop: LineStop) {}

    /// The line a row is printed as now (the focused one as typed).
    public func line(of stop: LineStop) -> String? { nil }

    /// Starts the session where its shape's first or last stop is, or a press at a world point puts it.
    func start() {}
}

extension LineRowsView {
    /// The editing view of `shape`, a kind written as lines by `model`, with its title typed in its pill (`title`, nil for
    /// a kind with no title stop). Where it starts: a press's point, else the title of an untitled shape, else the waiting
    /// line at the end; the last stop for a shape ⇧Tab came back to.
    public static func make<Model: LineModel>(_ shape: ShapeRecord<Model.Props>, context: EditContext<Model.Props>, model: Model,
                                              title: LineTitle?) -> EditingView {
        guard let service = context.service(LineRowsService.self) else {
            // No session without its plugin: the title alone, if there is one.
            let view = LineRowsView(frame: .zero)
            return EditingView(view: view, firstResponder: view.field)
        }
        let view = LineSession(shape: shape, context: context, model: model, title: title, service: service)
        view.start()
        return EditingView(view: view, firstResponder: view.focusedResponder)
    }
}

/// The session, over one shape of one kind.
@MainActor
final class LineSession<Model: LineModel>: LineRowsView {
    typealias Row = Model.Row
    let id: ShapeID
    let context: EditContext<Model.Props>
    let model: Model
    let service: LineRowsService
    var editor: CanvasEditor { service.editor }
    /// Where the waiting line is while it has the caret: an index among the rows.
    private var waitingAt = 0
    /// The row as it's stored, that the field shows (nil on the waiting line).
    private var held: Row?
    /// What the field's line reads as now.
    private var reading: LineReading<Row>?
    /// A move of the caret under way: the field leaving a row isn't the keyboard leaving.
    private var isMoving = false
    /// How far the field's text is slid left in its clip, so the caret stays in it.
    private var slide: CGFloat = 0
    /// The elements VoiceOver reads for the rows without the caret, by stop.
    private var elements: [LineStop: LineRowElement] = [:]

    init(shape: ShapeRecord<Model.Props>, context: EditContext<Model.Props>, model: Model, title: LineTitle?, service: LineRowsService) {
        id = shape.id
        self.context = context
        self.model = model
        self.service = service
        super.init(frame: .zero)
        field.plain = model.style.plain
        field.font = model.style.font
        field.insertionPointColor = model.style.ink
        field.onKey = { [weak self] key in self?.handle(key) ?? false }
        field.onChange = { [weak self] in self?.lineChanged() }
        field.onPasteLines = { [weak self] text in self?.paste(text) ?? false }
        field.onBlur = { [weak self] in self?.blurred() }
        field.offering = { [weak self] in self?.offers() }
        field.onLight = { [weak service] light in service?.setLight(light) }
        if let title {
            let titleField = title.make(shape[TitleProperty.self])
            titleField.typed = { [context, id] text in
                let title = TitleProperty.folded(text)
                guard context.shape?[TitleProperty.self] != title else { return }
                context.transact { $0.update(id) { $0[TitleProperty.self] = title } }
            }
            titleField.finished = { [weak self] ending in self?.titleEnded(ending) }
            titleField.onDown = { [weak self] in
                self?.step(by: 1)
                return true
            }
            addSubview(titleField)
            self.titleField = titleField
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    // MARK: Reading the shape

    private var shape: ShapeRecord<Model.Props>? { context.shape }
    var rows: [Row] { shape.map { model.rows(of: $0.props) } ?? [] }

    private func index(of row: PartID) -> Int? { rows.firstIndex { model.id(of: $0) == row } }

    /// Where the waiting line is drawn: where it has the caret, else last.
    private var waitingLine: Int { focus == .waiting ? min(waitingAt, rows.count) : rows.count }

    override var stops: [LineStop] {
        var stops: [LineStop] = titleField == nil ? [] : [.title]
        var lines = rows.map { LineStop.row(model.id(of: $0)) }
        lines.insert(.waiting, at: waitingLine)
        stops += lines
        return stops
    }

    private func lineContext(_ row: PartID? = nil) -> LineContext { LineContext(editor: editor, shape: id, row: row) }

    /// The grammar of the stop with the caret.
    private var grammar: any LineGrammar<Row> {
        switch focus {
        case .row(let row): model.grammar(for: rows.first { model.id(of: $0) == row }.map(model.role(of:)) ?? model.roleOfNewRow(at: rows.count, in: shape!.props))
        default: model.grammar(for: shape.map { model.roleOfNewRow(at: waitingAt, in: $0.props) } ?? "")
        }
    }

    override func line(of stop: LineStop) -> String? {
        if stop == focus { return field.string }
        guard case .row(let row) = stop, let held = rows.first(where: { model.id(of: $0) == row }) else { return stop == .waiting ? "" : nil }
        return model.grammar(for: model.role(of: held)).print(held, in: lineContext(row)).string
    }

    // MARK: Starting

    override func start() {
        let untitled = shape?[TitleProperty.self] == nil
        // Before the press is placed: the rows are where the kind drew them, the waiting line last.
        waitingAt = rows.count
        let hopped = service.startingStop(id)
        if hopped == .last {
            show(.waiting, at: .end, waitingAt: rows.count)
        } else if hopped == .first, let first = stops.first {
            show(first, at: .end, waitingAt: rows.count)
        } else if let point = context.startPoint, let stop = stop(at: point) {
            show(stop, at: .point(point, clicks: context.startClickCount), waitingAt: rows.count)
        } else if untitled, titleField != nil {
            show(.title, at: .end, waitingAt: rows.count)
        } else {
            show(.waiting, at: .end, waitingAt: rows.count)
        }
    }

    /// The stop a press at a world point is on: the pill's row is the title, a row's line the row, any other the waiting
    /// line.
    private func stop(at point: CGPoint) -> LineStop? {
        guard let paper else { return nil }
        if titleField != nil, point.y < paper.minY { return .title }
        for (index, row) in rows.enumerated() {
            let rect = model.lineRect(LineRowsLayout.line(of: index, waiting: waitingLine), in: paper)
            if point.y >= rect.minY, point.y < rect.maxY { return .row(model.id(of: row)) }
        }
        return .waiting
    }

    // MARK: Where things are

    /// The shape's paper, as it's laid out now, world units.
    private var paper: CGRect? {
        guard let record = editor.document[id] else { return nil }
        return editor.shapeContext.frame(of: record)
    }

    /// The editing frame's origin, world units: the view's bounds' origin.
    private var origin: CGPoint { context.frame?.origin ?? .zero }

    /// Line `line`'s rect, in the view's coordinates.
    private func rect(ofLine line: Int) -> CGRect? {
        guard let paper else { return nil }
        let origin = origin
        return model.lineRect(line, in: paper).offsetBy(dx: -origin.x, dy: -origin.y)
    }

    /// The rect of a stop's line, in the view's coordinates (nil for the title).
    func rect(of stop: LineStop) -> CGRect? {
        switch stop {
        case .title: return nil
        case .waiting: return rect(ofLine: waitingLine)
        case .row(let row): return index(of: row).flatMap { rect(ofLine: LineRowsLayout.line(of: $0, waiting: waitingLine)) }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        place()
    }

    override func layout() {
        super.layout()
        place()
    }

    /// The title's field on the pill's row, the line's over its stop.
    private func place() {
        if let titleField, let paper, frame.width > 0, bounds.width > 0 {
            let zoom = frame.width / bounds.width, origin = origin
            let row = TitleField.pillRow(above: paper, zoom: zoom).offsetBy(dx: -origin.x, dy: -origin.y)
            if titleField.frame != row { titleField.frame = row }
        }
        guard let line = rect(of: focus) else {
            clip.isHidden = true
            return
        }
        clip.isHidden = false
        let style = model.style
        let clipFrame = CGRect(x: line.minX + style.textInset, y: line.minY, width: max(1, line.width - style.textInset - style.trailingInset), height: line.height)
        if clip.frame != clipFrame { clip.frame = clipFrame }
        let height = ceil(field.layoutManagerLineHeight(style))
        let fieldFrame = CGRect(x: -slide, y: ((line.height - height) / 2).rounded(), width: max(textWidth + 4, clipFrame.width + slide), height: height)
        if field.frame != fieldFrame { field.frame = fieldFrame }
        keepCaretInClip()
        needsDisplay = true
    }

    private var textWidth: CGFloat {
        guard let layout = field.textLayoutManager else { return 0 }
        layout.ensureLayout(for: layout.documentRange)
        return layout.usageBoundsForTextContainer.width
    }

    /// Slides the text so the caret stays in the clip.
    private func keepCaretInClip() {
        guard let caret = field.caretFrame else { return }
        let at = caret.offsetBy(dx: slide, dy: 0), limit = clip.frame.width - 1
        var next = slide
        if at.maxX - next > limit { next = at.maxX - limit }
        if at.minX - next < 0 { next = max(0, at.minX) }
        guard next != slide else { return }
        slide = next
        field.frame.origin.x = -slide
    }

    /// The band behind the line with the caret, and its gutter's mark as it reads now.
    override func draw(_ dirtyRect: NSRect) {
        guard let line = rect(of: focus) else { return }
        let style = model.style
        let band = line.insetBy(dx: style.bandInset, dy: 0)
        style.band.setFill()
        NSBezierPath(roundedRect: band, xRadius: 3, yRadius: 3).fill()
        guard let mark = reading?.mark,
              let image = NSImage(systemSymbolName: mark.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: style.markSize, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [mark.color]))) else { return }
        let size = image.size
        image.draw(in: CGRect(x: line.minX + style.gutterMiddle - size.width / 2, y: line.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Presses on the title's chip and on the paper's lines are the session's; anywhere else they go on to the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local: CGPoint
        if let superview {
            local = convert(point, from: superview)
        } else {
            guard frame.width > 0, frame.height > 0 else { return nil }
            local = CGPoint(x: bounds.minX + (point.x - frame.minX) * bounds.width / frame.width,
                            y: bounds.minY + (point.y - frame.minY) * bounds.height / frame.height)
        }
        if let titleField, let hit = titleField.hitTest(local) { return hit }
        guard let paper, bounds.contains(local) else { return nil }
        let inPaper = paper.offsetBy(dx: -origin.x, dy: -origin.y)
        guard inPaper.contains(local) else { return nil }
        if !clip.isHidden, clip.frame.contains(local) { return field }
        return self
    }

    /// A press on another line goes to it, the caret where it was.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), origin = origin
        guard let stop = stop(at: CGPoint(x: point.x + origin.x, y: point.y + origin.y)), stop != focus else { return }
        go(to: stop, at: .point(CGPoint(x: point.x + origin.x, y: point.y + origin.y), clicks: event.clickCount))
    }

    // MARK: Showing a stop

    /// Where the caret goes in a line it moves to.
    enum Caret {
        case start, end
        /// Across from where it was, view x.
        case x(CGFloat)
        /// Where a press was, world units.
        case point(CGPoint, clicks: Int)
    }

    /// Puts the caret in `stop`, its line shown as stored, and tells the kind what to draw.
    private func show(_ stop: LineStop, at caret: Caret, waitingAt: Int? = nil) {
        isMoving = true
        defer { isMoving = false }
        focus = stop
        if let waitingAt { self.waitingAt = waitingAt }
        slide = 0
        switch stop {
        case .title:
            held = nil
            reading = nil
            field.closeOffers()
        case .waiting:
            held = nil
            field.substitutions = grammar.substitutions
            field.show(LineText(""), caret: 0)
            lineChanged(reportingChange: false)
        case .row(let row):
            let stored = rows.first { model.id(of: $0) == row }
            held = stored
            field.substitutions = grammar.substitutions
            field.show(stored.map { grammar.print($0, in: lineContext(row)) } ?? LineText(""))
            lineChanged(reportingChange: false)
        }
        setInputs()
        place()
        if stop != .title {
            switch caret {
            case .start: field.setSelectedRange(NSRange(location: 0, length: 0))
            case .end: field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
            case .x(let x): field.placeSelection(at: CGPoint(x: x - clip.frame.minX + slide, y: field.bounds.midY))
            case .point(let point, let clicks):
                let origin = origin
                let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
                field.placeSelection(at: field.convert(local, from: self), selectingWord: clicks >= 2)
            }
            keepCaretInClip()
            if case .row(let row) = stop, let index = index(of: row) {
                field.setAccessibilityLabel("\(model.noun.title) \(index + 1) of \(rows.count)")
            } else {
                field.setAccessibilityLabel("New \(model.noun.singular)")
            }
        }
        if let window {
            let responder = focusedResponder
            if window.firstResponder !== responder { window.makeFirstResponder(responder) }
        }
        elements = [:]
        setAccessibilityLabel(groupLabel)
        NSAccessibility.post(element: focusedResponder, notification: .focusedUIElementChanged)
        if let rect = stop == .title ? titleField?.frame : rect(of: stop) { context.keepInView(rect) }
        needsDisplay = true
    }

    /// What the kind reads: where the waiting line is, and which row the field draws.
    private func setInputs() {
        editor.setLayoutInput(LineRowsLayout.waiting, waitingLine, for: id)
        if case .row(let row) = focus {
            editor.setLayoutInput(LineRowsLayout.focused, row, for: id)
        } else {
            editor.setLayoutInput(LineRowsLayout.focused, nil, for: id)
        }
    }

    /// The line was typed in: read again, its looks and mark shown, the clip slid to the caret.
    private func lineChanged(reportingChange: Bool = true) {
        guard focus != .title else { return }
        let rowID: PartID
        if case .row(let row) = focus { rowID = row } else { rowID = PartID() }
        let read = grammar.read(field.line, id: rowID, in: lineContext(focus == .waiting ? nil : rowID))
        reading = read
        field.show(read, style: model.style)
        if reportingChange {
            place()
            keepCaretInClip()
        }
        needsDisplay = true
    }

    private func offers() -> LineOffers? {
        guard focus != .title, let reading else { return nil }
        let row: PartID? = if case .row(let row) = focus { row } else { nil }
        return grammar.offers(at: field.selectedRange().location, in: field.line, reading: reading, context: lineContext(row))
    }

    // MARK: Committing

    /// Writes the line with the caret, if it changed what's stored: a row added from the waiting line, a row changed, or a
    /// row emptied taken out; one step the kind names. The row it is after, or nil where nothing was written.
    @discardableResult
    func commitDraft() -> LineStop? {
        guard focus != .title, editor.canTransact, editor.document[id] != nil else { return nil }
        let line = field.line
        let blank = line.string.trimmingCharacters(in: .whitespaces).isEmpty
        switch focus {
        case .waiting:
            guard !blank, let row = grammar.read(line, id: PartID(), in: lineContext()).row else { return nil }
            let at = min(waitingAt, rows.count)
            guard write([.add([row], at: at)]) else { return nil }
            // The line is that row now: written again, it changes nothing.
            focus = .row(model.id(of: row))
            held = rows.first { model.id(of: $0) == model.id(of: row) }
            return focus
        case .row(let rowID):
            guard let current = rows.first(where: { model.id(of: $0) == rowID }) else { return nil }
            if blank {
                guard write([.delete([current])]) else { return nil }
                focus = .waiting
                waitingAt = rows.count
                held = nil
                return .waiting
            }
            guard let read = grammar.read(line, id: rowID, in: lineContext(rowID)).row else { return nil }
            let merged = model.merged(read, onto: current)
            guard merged != current else { return focus }
            guard write([.change(from: current, to: merged)]) else { return nil }
            held = rows.first { model.id(of: $0) == rowID }
            return .row(rowID)
        case .title:
            return nil
        }
    }

    /// One step of `changes`, named as the kind names the first (and what a delete took along); heard by VoiceOver. A
    /// refusal (a locked shape) writes nothing and shakes the shape.
    @discardableResult
    private func write(_ changes: [LineChange<Row>], coalescing key: AnyHashable? = nil) -> Bool {
        var name = ""
        let model = model, id = id, registry = editor.registry
        let written: Bool? = editor.transactWhole(nil, coalescing: key, shaking: [id]) { transaction in
            guard model.apply(changes, to: id, in: &transaction) else { throw Transaction.Refused([id]) }
            name = model.stepName(of: changes, along: transaction.deletedAlong, in: registry)
            transaction.stepName = name
            return true
        }
        guard written == true else { return false }
        editor.announce(name)
        return true
    }

    /// The keyboard left the line for somewhere else (a click away, another window): what it held is written.
    private func blurred() {
        guard !isMoving else { return }
        commitDraft()
    }

    // MARK: Keys

    private func handle(_ key: LineKey) -> Bool {
        switch key {
        case .commit: returnPressed()
        case .up: step(by: -1)
        case .down: step(by: 1)
        case .next: tab(by: 1)
        case .previous: tab(by: -1)
        case .end: end()
        case .moveUp: move(by: -1)
        case .moveDown: move(by: 1)
        case .addBeside: addBeside()
        case .deleteEmpty: return deleteEmpty()
        }
        return true
    }

    /// Return: on the title, the waiting line; on a line with words, the line committed and a waiting line under it; on an
    /// empty line, editing ends (an emptied row going as it does).
    private func returnPressed() {
        let blank = field.string.trimmingCharacters(in: .whitespaces).isEmpty
        switch focus {
        case .title:
            show(.waiting, at: .end, waitingAt: rows.count)
        case .waiting where blank:
            end()
        case .row where blank:
            end()
        case .waiting:
            let at = min(waitingAt, rows.count)
            guard commitDraft() != nil else { return }
            show(.waiting, at: .end, waitingAt: at + 1)
        case .row(let row):
            commitDraft()
            let at = index(of: row).map { $0 + 1 } ?? rows.count
            show(.waiting, at: .end, waitingAt: at)
        }
    }

    /// ↑ ↓: the stop above or below, the caret across from where it was; nothing past the ends.
    private func step(by delta: Int) {
        let stops = stops
        guard let at = stops.firstIndex(of: focus) else { return }
        let to = at + delta
        guard stops.indices.contains(to) else { return }
        let x = field.caretFrame.map { $0.minX - slide + clip.frame.minX }
        go(to: stops[to], at: x.map(Caret.x) ?? .end)
    }

    /// Tab ⇧Tab: the next or previous stop, the caret at its line's end; past the ends, the next or previous shape of the
    /// kind (its first or last stop), or with none, round to this one's other end.
    private func tab(by delta: Int) {
        let stops = stops
        guard let at = stops.firstIndex(of: focus) else { return }
        let to = at + delta
        if stops.indices.contains(to) { return go(to: stops[to], at: .end) }
        commitDraft()
        if service.hop(delta > 0 ? .next : .previous, from: id) { return }
        let round = self.stops
        guard let target = delta > 0 ? round.first : round.last else { return }
        show(target == .waiting ? .waiting : target, at: .end, waitingAt: rows.count)
    }

    /// The caret to `stop`, committing the line it leaves; a stop the commit changed is found again.
    override func go(to stop: LineStop) { go(to: stop, at: .end) }

    private func go(to stop: LineStop, at caret: Caret) {
        guard stop != focus else { return }
        commitDraft()
        switch stop {
        case .title: show(.title, at: caret)
        case .row(let row) where index(of: row) != nil: show(stop, at: caret)
        // The waiting line, or a row that went with the line it was (emptied and left): the waiting line, last.
        default: show(.waiting, at: caret, waitingAt: rows.count)
        }
    }

    /// Escape, ⌘↩, ⌘↑: the line written, editing ends.
    private func end() {
        commitDraft()
        context.end()
    }

    /// ⌥↑ ⌥↓: the row one place up or down, the line written first; held or repeated, one step ("Move Column").
    private func move(by delta: Int) {
        if focus == .waiting, let added = commitDraft() {
            show(added, at: .end)
        } else if case .row = focus {
            commitDraft()
        }
        guard case .row(let row) = focus, let at = index(of: row), let held = rows.first(where: { model.id(of: $0) == row }) else { return }
        let to = at + delta
        guard rows.indices.contains(to) else { return }
        let caret = field.selectedRange()
        guard write([.move(held, to: to)], coalescing: LineMoveRun(shape: id, row: row)) else { return }
        show(.row(row), at: .start)
        field.setSelectedRange(NSRange(location: min(caret.location, (field.string as NSString).length), length: 0))
    }

    /// ⇧↩: the line written, editing ends, and a shape of the kind goes beside this one, edited (Insert's beside).
    private func addBeside() {
        commitDraft()
        guard let kind = editor.document[id]?.kind else { return }
        if !editor.insert(ToolID(placing: kind), beside: [id]) { editor.refuseChanges(to: [id]) }
    }

    /// ⌫ on an empty line: a row goes, one step ("Delete Column"), the caret to the end of the row above (else the start of
    /// the one below), and a held ⌫ stops there; on the waiting line, the caret goes to the row above, nothing written.
    private func deleteEmpty() -> Bool {
        switch focus {
        case .title:
            return false
        case .waiting:
            let stops = stops
            guard let at = stops.firstIndex(of: .waiting), at > 0, case .row = stops[at - 1] else { return true }
            show(stops[at - 1], at: .end)
            return true
        case .row(let row):
            guard let at = index(of: row), let current = rows.first(where: { model.id(of: $0) == row }) else { return true }
            guard write([.delete([current])]) else { return true }
            field.swallowsDeleteRepeats = true
            let left = rows
            if at > 0, left.indices.contains(at - 1) {
                show(.row(model.id(of: left[at - 1])), at: .end)
            } else if let first = left.first {
                show(.row(model.id(of: first)), at: .start)
            } else {
                show(.waiting, at: .start, waitingAt: 0)
            }
            return true
        }
    }

    /// A block of lines pasted: a row a line, where the caret's line is (in place of it when it's empty, after it
    /// otherwise), one step ("Paste Columns"); the caret at the end of the last. One line is typed.
    private func paste(_ text: String) -> Bool {
        guard focus != .title else { return false }
        let lines = grammar.lines(fromPasted: text)
        guard lines.count > 1 else {
            if let line = lines.first { field.insertText(line, replacementRange: field.selectedRange()) }
            return true
        }
        let blank = field.string.trimmingCharacters(in: .whitespaces).isEmpty
        var changes: [LineChange<Row>] = []
        var at: Int
        switch focus {
        case .waiting:
            if !blank, let added = commitDraft(), case .row(let row) = added {
                at = index(of: row).map { $0 + 1 } ?? rows.count
            } else {
                at = min(waitingAt, rows.count)
            }
        case .row(let row):
            guard let index = index(of: row), let current = rows.first(where: { model.id(of: $0) == row }) else { return true }
            if blank {
                changes.append(.delete([current]))
                at = index
            } else {
                commitDraft()
                at = (self.index(of: row) ?? index) + 1
            }
        case .title:
            return false
        }
        let grammar = model.grammar(for: shape.map { model.roleOfNewRow(at: at, in: $0.props) } ?? "")
        let made = lines.compactMap { grammar.read(LineText($0), id: PartID(), in: lineContext()).row }
        guard !made.isEmpty else { return true }
        changes.append(.add(made, at: at))
        isMoving = true
        defer { isMoving = false }
        guard write(changes) else { return true }
        show(.row(model.id(of: made[made.count - 1])), at: .end)
        return true
    }

    /// The title's field ended: Return to the waiting line, Tab on, ⇧Tab back, Escape out.
    private func titleEnded(_ ending: TitleField.Ending) {
        switch ending {
        case .done: show(.waiting, at: .end, waitingAt: rows.count)
        case .escape: context.end()
        case .tab: tab(by: 1)
        case .backTab: tab(by: -1)
        }
    }

    // MARK: VoiceOver

    /// "Columns of orders".
    private var groupLabel: String {
        let title = shape?[TitleProperty.self]
        return title.map { "\(model.noun.pluralTitle) of \($0)" } ?? model.noun.pluralTitle
    }

    override func accessibilityLabel() -> String? { groupLabel }

    /// The title's field, then a row's element each (the one with the caret is the field), then the waiting line.
    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = []
        if let titleField { children.append(titleField.field) }
        let rows = rows
        for stop in stops where stop != .title {
            if stop == focus {
                children.append(field)
                continue
            }
            let element = elements[stop] ?? LineRowElement()
            elements[stop] = element
            element.setAccessibilityRole(.textField)
            element.setAccessibilityParent(self)
            switch stop {
            case .row(let row):
                guard let at = index(of: row) else { continue }
                let held = rows[at]
                let grammar = model.grammar(for: model.role(of: held))
                element.setAccessibilityLabel("\(model.noun.title) \(at + 1) of \(rows.count)")
                element.setAccessibilityValue(grammar.print(held, in: lineContext(row)).string)
                element.setAccessibilityHelp(grammar.spoken(held, in: lineContext(row)))
            default:
                element.setAccessibilityLabel("New \(model.noun.singular)")
                element.setAccessibilityValue("")
            }
            if let rect = rect(of: stop), let window {
                element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            }
            element.press = { [weak self] in self?.go(to: stop) }
            children.append(element)
        }
        return children
    }
}

/// A row without the caret, as VoiceOver reads it: a text field, "Column 3 of 5", its line the value; pressed, the caret
/// goes there.
final class LineRowElement: NSAccessibilityElement {
    /// What pressing it does: the caret to its row. Set and used on the main thread, where AppKit asks.
    nonisolated(unsafe) var press: (@MainActor () -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        MainActor.assumeIsolated { press() }
        return true
    }
}

extension LineField {
    /// How tall its line is in the kind's fonts: what it's centered in a row by.
    func layoutManagerLineHeight(_ style: LineStyle) -> CGFloat {
        max(style.font.ascender - style.font.descender + style.font.leading, style.codeFont.ascender - style.codeFont.descender + style.codeFont.leading)
    }
}
