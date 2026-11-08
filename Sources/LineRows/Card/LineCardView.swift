import AppKit
import Canvas
import TextEditing

// A row's card, as it shows in its core card under the row: the header (the row's name, with its mark, in a chip) and a line a
// stop of what the kind gives (`LineCard`): words in a line field (one per field, one per item of a list), a toggle said yes or
// no, a choice said by its option. The keys walk it as a form: Tab and ⇧Tab round its stops, ↑ ↓ between them, staying at the
// ends; Escape, ⌘↑ and ⌘. give the row its keyboard back; ⌘↩ ends editing; Return in a field is done with it (the row has the
// keyboard back), and in a list opens a line below it (on an empty one, done); Space and Return toggle a toggle and open a
// choice. A line commits as its stop is left (a toggle and a pick at once), the row's step, named by the kind.

/// A row's card, as a test and VoiceOver read it, whatever its rows are.
@MainActor
public class LineCardView: NSView {
    /// The row it is about, as the row is now: the kind is asked again as the card follows the row.
    public internal(set) var header: LineCardHeader
    /// Told when the header changed (the row was renamed, its mark changed): what names the card is named again.
    var headerDidChange: (@MainActor (LineCardHeader) -> Void)?
    /// Shows a choice's menu in place of popping it up (a test chooses from it, as a click would).
    public var menuPresenter: (@MainActor (NSMenu) -> Void)?

    init(header: LineCardHeader) {
        self.header = header
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// Its stops, in order: a line's label, a list's items by their place ("notes 2").
    public var stopNames: [String] { [] }
    /// The stop with the keyboard, if one has it.
    public var focusedStop: String? { nil }
    /// What a stop shows: its line, "yes" or "no", its option.
    public func value(of stop: String) -> String? { nil }
    /// The line field of a stop of words.
    public func field(of stop: String) -> LineField? { nil }
    /// The keyboard to a stop, as a key would take it (the one it leaves written).
    public func go(to stop: String) {}
}

/// Which stop: the card's line, and its item in a list (0 for any other line).
struct CardStop: Hashable {
    var line: Int
    var item: Int
}

/// The card of one row of a shape a session edits.
@MainActor
final class LineCardSession<Model: LineModel>: LineCardView {
    typealias Row = Model.Row
    private weak var session: LineSession<Model>?
    private let card: LineCard<Row>
    let row: PartID
    private let editor: CanvasEditor
    /// The row as stored when its lines were last shown: what a line's change is written over.
    private var held: Row
    /// The views of each line: a line of words' fields (one; a list's, an item each), or a toggle's or a choice's control.
    private var texts: [Int: TextLine] = [:]
    private var controls: [Int: LineCardControl] = [:]
    /// The stop with the keyboard (the card's own; the keyboard may be elsewhere while it's shown).
    private var focus = CardStop(line: 0, item: 0)
    /// A move of the keyboard under way: a field it leaves isn't the keyboard leaving the card.
    private var isMoving = false
    /// A commit is waiting for the file to take one (`writeLater`).
    private var writingLater = false
    private let style: LineStyle

    /// A line of words: its fields, what each was given, and a list's line opened by Return and not yet written.
    final class TextLine {
        let text: LineCardText<Row>
        var fields: [LineField] = []
        var clips: [NSView] = []
        var shown: [LineText] = []
        var pending: Int?

        init(_ text: LineCardText<Row>) { self.text = text }
    }

    init(card: LineCard<Row>, row: PartID, session: LineSession<Model>, editor: CanvasEditor) {
        self.session = session
        self.card = card
        self.row = row
        self.editor = editor
        held = session.storedRow(row)!
        style = LineCardStyle.lineStyle(from: session.style)
        super.init(header: card.header)
        for (index, line) in card.lines.enumerated() {
            switch line.kind {
            case .text(let text): texts[index] = TextLine(text)
            case .toggle, .choice:
                let control = LineCardControl(label: line.label)
                control.onKey = { [weak self] key in self?.key(key, at: CardStop(line: index, item: 0)) ?? false }
                control.onPress = { [weak self] in self?.press(line: index) }
                control.onFocus = { [weak self] in self?.focused(CardStop(line: index, item: 0)) }
                if case .choice = line.kind { control.role = .popUpButton } else { control.role = .checkBox }
                addSubview(control)
                controls[index] = control
            }
        }
        reload()
        if let first = stops.first { focus = first }
    }

    // MARK: Reading the row

    private var context: LineContext { LineContext(editor: editor, shape: session?.id ?? ShapeID(), row: row) }

    /// Shows what the row holds now: every line but one with the person's words in it, unless `keepingDrafts` is false (a line
    /// just written, or refused, shows what's stored).
    @discardableResult
    func reload(keepingDrafts: Bool = true) -> Bool {
        guard let session, let stored = session.storedRow(row) else { return false }
        let countBefore = stops.count
        held = stored
        let context = context
        if let fresh = session.model.card(of: stored, in: context)?.header, fresh != header {
            header = fresh
            headerDidChange?(fresh)
        }
        for (index, line) in texts.sorted(by: { $0.key < $1.key }) {
            var lines = line.text.lines(stored, context)
            if line.text.isList {
                if let pending = line.pending { lines.insert(LineText(""), at: min(pending, lines.count)) }
                if lines.isEmpty { lines = [LineText("")] }
            } else {
                lines = [lines.first ?? LineText("")]
            }
            setFields(of: line, count: lines.count, at: index)
            for (item, text) in lines.enumerated() {
                let field = line.fields[item]
                // A line with words of the person's keeps them.
                if keepingDrafts, item < line.shown.count, field.line != line.shown[item], window?.firstResponder === field { continue }
                if item < line.shown.count { line.shown[item] = text } else { line.shown.append(text) }
                field.show(text)
                looks(of: field, in: line)
            }
            line.shown = Array(line.shown.prefix(lines.count))
        }
        for (index, control) in controls {
            switch card.lines[index].kind {
            case .toggle(let get, _):
                control.value = get(stored) ? LineCardStyle.yes : LineCardStyle.no
                control.isFaint = false
            case .choice(let options, let get, _):
                let current = get(stored)
                control.value = current.map { Self.option($0, in: options) } ?? options.first ?? ""
                control.isFaint = current == nil
            case .text: break
            }
        }
        if focus.line >= card.lines.count || !stops.contains(focus) { focus = stops.last { $0.line == focus.line } ?? stops.first ?? focus }
        nameFields()
        needsLayout = true
        needsDisplay = true
        return stops.count != countBefore
    }

    /// An option as listed, for words as stored ("CASCADE" is cascade).
    private static func option(_ stored: String, in options: [String]) -> String {
        options.first { $0.caseInsensitiveCompare(stored) == .orderedSame } ?? stored
    }

    /// `line` holding `count` fields, made or taken down to fit.
    private func setFields(of line: TextLine, count: Int, at index: Int) {
        while line.fields.count < count {
            let field = LineField()
            let clip = NSView()
            clip.clipsToBounds = true
            clip.addSubview(field)
            addSubview(clip)
            field.plain = style.plain
            field.font = style.font
            field.insertionPointColor = style.ink
            field.substitutions = line.text.substitutions
            field.onKey = { [weak self, weak field] key in
                guard let self, let field, let stop = self.stop(of: field) else { return false }
                return self.key(key, at: stop)
            }
            field.onChange = { [weak self, weak field] in
                guard let self, let field, let line = self.textLine(of: field) else { return }
                self.looks(of: field, in: line)
                self.placeFields()
            }
            field.onBlur = { [weak self, weak field] in
                guard let self, let field, !self.isMoving, let stop = self.stop(of: field) else { return }
                self.commit(stop.line, leaving: stop.item)
            }
            field.onFocus = { [weak self, weak field] in
                guard let self, let field, let stop = self.stop(of: field) else { return }
                self.focused(stop)
            }
            field.offering = { [weak self, weak field] in
                guard let self, let field, let line = self.textLine(of: field) else { return nil }
                return line.text.offers(field.selectedRange().location, field.line, self.context)
            }
            field.draft = { [weak self, weak field] in
                guard let self, let field, let line = self.textLine(of: field), let index = line.fields.firstIndex(where: { $0 === field }) else { return false }
                return index < line.shown.count && field.line != line.shown[index]
            }
            field.onLight = { [weak self] light in self?.session?.service.setLight(light) }
            field.onAction = { [weak self, weak field] action, range in
                guard let self, let field, let stop = self.stop(of: field) else { return }
                self.act(action, at: range, in: field, stop: stop)
            }
            line.fields.append(field)
            line.clips.append(clip)
        }
        while line.fields.count > count {
            line.fields.removeLast().onBlur = nil
            line.clips.removeLast().removeFromSuperview()
        }
    }

    /// The field's line read as its grammar reads it: its looks.
    private func looks(of field: LineField, in line: TextLine) {
        let look = line.text.look(field.line, context)
        field.show(LineReading<Bool>(row: nil, spans: look.spans, mark: look.mark), style: style)
    }

    private func textLine(of field: LineField) -> TextLine? { texts.values.first { $0.fields.contains { $0 === field } } }

    private func stop(of field: LineField) -> CardStop? {
        for (index, line) in texts {
            if let item = line.fields.firstIndex(where: { $0 === field }) { return CardStop(line: index, item: item) }
        }
        return nil
    }

    // MARK: Stops

    /// Every stop, in order: each line's, a list's an item each.
    var stops: [CardStop] {
        card.lines.indices.flatMap { index -> [CardStop] in
            let count = texts[index]?.fields.count ?? 1
            return (0..<max(count, 1)).map { CardStop(line: index, item: $0) }
        }
    }

    private func name(of stop: CardStop) -> String {
        let label = card.lines[stop.line].label
        guard let line = texts[stop.line], line.text.isList else { return label }
        return "\(label) \(stop.item + 1)"
    }

    private func responder(of stop: CardStop) -> NSView? {
        if let line = texts[stop.line] { return line.fields.indices.contains(stop.item) ? line.fields[stop.item] : nil }
        return controls[stop.line]
    }

    /// What has the keyboard as the card shows: its first stop.
    var firstResponderStop: NSResponder? { stops.first.flatMap(responder(of:)) }

    override var stopNames: [String] { stops.map(name(of:)) }

    override var focusedStop: String? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        return stops.first { self.responder(of: $0) === responder }.map(name(of:))
    }

    override func value(of stop: String) -> String? {
        guard let found = stops.first(where: { name(of: $0) == stop }) else { return nil }
        if let line = texts[found.line] { return line.fields[found.item].string }
        return controls[found.line]?.value
    }

    override func field(of stop: String) -> LineField? {
        guard let found = stops.first(where: { name(of: $0) == stop }), let line = texts[found.line] else { return nil }
        return line.fields[found.item]
    }

    override func go(to stop: String) {
        guard let found = stops.first(where: { name(of: $0) == stop }) else { return }
        move(to: found)
    }

    /// The keyboard came to a stop (a key, a click, VoiceOver).
    private func focused(_ stop: CardStop) {
        focus = stop
        needsDisplay = true
        if let responder = responder(of: stop) { NSAccessibility.post(element: responder, notification: .focusedUIElementChanged) }
    }

    /// The keyboard to `stop`, the line it leaves written first; a stop the write changed is found again by its place, and by
    /// what it was: a list's line before it written away (left empty) moves the ones after it up.
    private func move(to stop: CardStop) {
        let leaving = focus
        isMoving = true
        defer { isMoving = false }
        var target = stop
        if leaving.line != stop.line || texts[leaving.line]?.text.isList == true {
            let line = texts[stop.line]
            let before = line?.fields.count ?? 1
            let above = leaving.line == stop.line ? emptyItems(of: stop.line, before: stop.item) : 0
            commit(leaving.line, leaving: leaving.item)
            if above > 0 { target.item = max(0, stop.item - min(above, before - (texts[stop.line]?.fields.count ?? 1))) }
        }
        let all = stops
        let aimed = all.contains(target) ? target : (all.last { $0.line == stop.line } ?? all.first ?? stop)
        focus = aimed
        if let responder = responder(of: aimed), let window, window.firstResponder !== responder {
            window.makeFirstResponder(responder)
            if let field = responder as? LineField { field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0)) }
        }
        needsDisplay = true
    }

    /// How many of a list's items before `item` hold nothing its grammar reads: the ones a write takes out.
    private func emptyItems(of index: Int, before item: Int) -> Int {
        guard let line = texts[index], line.text.isList else { return 0 }
        return line.fields.prefix(item).filter { line.text.isEmpty($0.line, context) }.count
    }

    // MARK: Committing

    /// A line of words left (`item` of it, the field the keyboard left): the row written with what its lines say, if they changed
    /// what it was shown, one step the kind names. A refusal (the file can't take it, the shape refused and shook) keeps what
    /// was typed where it is, as a row's line keeps its draft; where the file can't take a commit just now (a card closed as a
    /// commit is delivered) it is written a turn later.
    @discardableResult
    private func commit(_ index: Int, leaving item: Int? = nil) -> CardCommit {
        guard let line = texts[index], let session else { return .unchanged }
        let lines = line.fields.map(\.line)
        // An empty line Return opened and the person left untouched goes.
        let abandoned = item != nil && line.pending == item && line.text.isEmpty(lines[item!], context)
        guard lines != line.shown || abandoned else { return .unchanged }
        guard editor.canTransact else {
            writeLater(index, leaving: item)
            return .refused
        }
        var result = CardCommit.unchanged
        if lines != line.shown {
            let written = line.text.write(lines, held, context)
            result = session.commitCard(written, over: held)
            if result == .refused { return .refused }
        }
        line.pending = nil
        // Written, or nothing changed: the lines show what the row holds now.
        let keep = isMoving
        isMoving = true
        reload(keepingDrafts: false)
        isMoving = keep
        editor.cardDidResize()
        return result
    }

    /// An action row done in a line of the card ("New type Problem"): what it makes, the line's words standing for it, and the line
    /// written with them, in one step of the action's name, heard by VoiceOver; the caret stays at the end of that line.
    private func act(_ action: LineAction, at range: NSRange, in field: LineField, stop: CardStop) {
        guard session != nil, editor.canTransact else { return }
        let context = context
        var result = CardCommit.unchanged
        editor.undoHistory.group(action.stepName) {
            guard let made = action.perform(context) else { return }
            field.stand(for: made, at: range)
            result = commit(stop.line)
        }
        guard result == .written else { return }
        editor.announce(action.stepName)
        if let kept = responder(of: stop) as? LineField, let window, window.firstResponder !== kept {
            window.makeFirstResponder(kept)
        }
        if let kept = responder(of: stop) as? LineField { kept.setSelectedRange(NSRange(location: (kept.string as NSString).length, length: 0)) }
    }

    /// A commit the file couldn't take while it was delivering one: made a turn later, if the line still has words to write.
    private func writeLater(_ index: Int, leaving item: Int?) {
        guard !writingLater else { return }
        writingLater = true
        _ = editor.scheduler.schedule(after: .zero) { [weak self] in
            guard let self else { return }
            self.writingLater = false
            let keep = self.isMoving
            self.isMoving = true
            self.commit(index, leaving: item)
            self.isMoving = keep
        }
    }

    /// Space, Return or a click on a toggle (flipped, written at once) or a choice (its options, the current checked).
    private func press(line index: Int) {
        guard let session else { return }
        switch card.lines[index].kind {
        case .toggle(let get, let set):
            var row = held
            set(&row, !get(held))
            session.commitCard(row, over: held)
            reload(keepingDrafts: false)
            spokenChange(of: index)
        case .choice(let options, let get, let set):
            let current = get(held).map { Self.option($0, in: options) } ?? options.first
            let menu = NSMenu(title: card.lines[index].label)
            var highlighted: NSMenuItem?
            for option in options {
                let item = NSMenuItem(title: option) { [weak self] in self?.choose(option, line: index, set: set) }
                if option == current {
                    item.state = .on
                    highlighted = item
                }
                menu.addItem(item)
            }
            if let menuPresenter {
                menuPresenter(menu)
            } else if let control = controls[index] {
                menu.popUp(positioning: highlighted, at: CGPoint(x: control.valueX - LineCardStyle.menuInset, y: control.bounds.maxY - LineCardStyle.menuDrop), in: control)
            }
        case .text:
            break
        }
    }

    private func choose(_ option: String, line index: Int, set: @MainActor (inout Row, String) -> Void) {
        guard let session, case .choice(let options, let get, _) = card.lines[index].kind else { return }
        // The option shown faint while none is held is none: picking it writes nothing.
        if get(held) == nil, option == options.first { return }
        var row = held
        set(&row, option)
        session.commitCard(row, over: held)
        reload(keepingDrafts: false)
        spokenChange(of: index)
    }

    /// What a toggle or a choice now says, spoken beside the step's name: "null yes", "on delete cascade".
    private func spokenChange(of index: Int) {
        guard let control = controls[index] else { return }
        editor.announce(LineCardStyle.spoken(card.lines[index].label, control.value))
    }

    // MARK: Keys

    private func key(_ key: LineKey, at stop: CardStop) -> Bool {
        focus = stop
        let all = stops
        guard let at = all.firstIndex(of: stop) else { return false }
        switch key {
        case .up:
            if at > 0 { move(to: all[at - 1]) }
        case .down:
            if at + 1 < all.count { move(to: all[at + 1]) }
        case .next:
            move(to: all[(at + 1) % all.count])
        case .previous:
            move(to: all[(at - 1 + all.count) % all.count])
        case .end:
            backToRow()
        case .finish:
            leave()
            session?.end()
        case .commit:
            returnPressed(at: stop)
        case .deleteEmpty:
            return deleteEmpty(at: stop)
        case .moveUp, .moveDown, .addBeside, .connect, .card:
            break
        }
        return true
    }

    /// Return: in a list, the line written and one opened below it, or on an empty line, done; in a field, done: the row has
    /// the keyboard back, unless the file refused the line (it stays, with its words and the shape shaking). A toggle's and a
    /// choice's is their press (`LineCardControl`).
    private func returnPressed(at stop: CardStop) {
        guard let line = texts[stop.line] else { return press(line: stop.line) }
        let field = line.fields[stop.item]
        let blank = field.string.trimmingCharacters(in: .whitespaces).isEmpty
        guard line.text.isList, !blank else {
            isMoving = true
            let result = commit(stop.line, leaving: stop.item)
            isMoving = false
            if result != .refused { close() }
            return
        }
        isMoving = true
        guard commit(stop.line, leaving: stop.item) != .refused else {
            isMoving = false
            return
        }
        // The new line goes after the one Return was on, as it's stored now: the item it was, or the last.
        let stored = line.text.lines(held, context).count
        line.pending = min(stop.item + 1, stored)
        reload(keepingDrafts: false)
        editor.cardDidResize()
        isMoving = false
        move(to: CardStop(line: stop.line, item: line.pending ?? 0))
    }

    /// ⌫ on an empty line of a list: it goes (written as the list is), the keyboard to the line above. Elsewhere it's the text's.
    private func deleteEmpty(at stop: CardStop) -> Bool {
        guard let line = texts[stop.line], line.text.isList, line.fields.count > 1 || line.pending != nil else { return false }
        isMoving = true
        if line.pending == stop.item {
            line.pending = nil
            reload()
        } else {
            commit(stop.line, leaving: stop.item)
        }
        editor.cardDidResize()
        isMoving = false
        move(to: CardStop(line: stop.line, item: max(0, stop.item - 1)))
        return true
    }

    /// The line with the keyboard written.
    private func leave() {
        isMoving = true
        commit(focus.line, leaving: focus.item)
        isMoving = false
    }

    /// Escape, ⌘↑, ⌘.: the line written, the card closes and the row has the keyboard back (as the row's own Escape, whether or
    /// not the file took the line).
    private func backToRow() {
        leave()
        close()
    }

    private func close() {
        isMoving = true
        editor.closeCard()
        isMoving = false
    }

    /// The core took the card down, for any reason: a line with words of the person's is written, if the file can take it (a
    /// turn later where it is delivering a commit).
    func didClose() {
        guard !isMoving else { return }
        isMoving = true
        commit(focus.line, leaving: focus.item)
        isMoving = false
    }

    // MARK: Where things are

    /// The row's rect now, world units; nil where it's gone.
    func anchorNow() -> CGRect? { session?.worldRect(of: row) }

    /// How large it wants to be in `room`, view points.
    func size(in room: CGSize) -> CGSize {
        let count = card.lines.indices.reduce(0) { $0 + max(texts[$1]?.fields.count ?? 1, 1) }
        let height = LineCardStyle.padding * 2 + LineCardStyle.headerHeight + LineCardStyle.headerGap + CGFloat(count) * LineCardStyle.lineHeight
        return CGSize(width: min(LineCardStyle.width, room.width), height: min(height, room.height))
    }

    /// The rect of a stop's line, view points.
    private func rect(of stop: CardStop) -> CGRect {
        var y = LineCardStyle.padding + LineCardStyle.headerHeight + LineCardStyle.headerGap
        for index in 0..<stop.line { y += CGFloat(max(texts[index]?.fields.count ?? 1, 1)) * LineCardStyle.lineHeight }
        y += CGFloat(stop.item) * LineCardStyle.lineHeight
        return CGRect(x: 0, y: y, width: bounds.width, height: LineCardStyle.lineHeight)
    }

    private var valueX: CGFloat { LineCardStyle.padding + LineCardStyle.labelWidth }

    override func layout() {
        super.layout()
        placeFields()
        for (index, control) in controls {
            let line = rect(of: CardStop(line: index, item: 0))
            let frame = CGRect(x: valueX - LineCardStyle.focusInset, y: line.minY, width: max(1, bounds.width - valueX - LineCardStyle.padding + LineCardStyle.focusInset), height: line.height)
            if control.frame != frame { control.frame = frame }
            control.valueX = LineCardStyle.focusInset
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Each field over its line's value, its text slid to keep the caret in view.
    private func placeFields() {
        for (index, line) in texts {
            for (item, field) in line.fields.enumerated() {
                let rect = rect(of: CardStop(line: index, item: item))
                let clipFrame = CGRect(x: valueX, y: rect.minY, width: max(1, bounds.width - valueX - LineCardStyle.padding), height: rect.height)
                let clip = line.clips[item]
                if clip.frame != clipFrame { clip.frame = clipFrame }
                let height = ceil(max(style.font.ascender - style.font.descender + style.font.leading,
                                      style.codeFont.ascender - style.codeFont.descender + style.codeFont.leading))
                var width = clipFrame.width
                if let layout = field.textLayoutManager {
                    layout.ensureLayout(for: layout.documentRange)
                    width = max(width, layout.usageBoundsForTextContainer.width + LineCardStyle.textSlack)
                }
                var x: CGFloat = 0
                if let caret = field.caretFrame, caret.maxX > clipFrame.width - 1 { x = -(caret.maxX - clipFrame.width + 1) }
                let frame = CGRect(x: x, y: ((rect.height - height) / 2).rounded(), width: width, height: height)
                if field.frame != frame { field.frame = frame }
            }
        }
    }

    /// VoiceOver reads the lines in the order the keys walk them, top to bottom, whatever order the views were added in.
    override func accessibilityChildren() -> [Any]? { stops.compactMap(responder(of:)) }

    /// The names VoiceOver reads for the fields: a line's label, a list's item by its place.
    private func nameFields() {
        for (index, line) in texts {
            for (item, field) in line.fields.enumerated() {
                let label = card.lines[index].label
                field.setAccessibilityLabel(line.text.isList ? LineCardStyle.item(label, item + 1, of: line.fields.count) : label)
            }
        }
    }

    // MARK: Drawing

    /// The header's chip, each line's label, and the band behind the stop with the keyboard.
    override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder.map({ responder in stops.contains { self.responder(of: $0) === responder } }) == true {
            let band = rect(of: focus).insetBy(dx: LineCardStyle.bandInset, dy: 1)
            LineCardStyle.band.setFill()
            NSBezierPath(roundedRect: band, xRadius: LineCardStyle.bandRadius, yRadius: LineCardStyle.bandRadius).fill()
        }
        drawHeader()
        let labels: [NSAttributedString.Key: Any] = [.font: LineCardStyle.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        for (index, line) in card.lines.enumerated() {
            let rect = rect(of: CardStop(line: index, item: 0))
            let text = NSAttributedString(string: line.label, attributes: labels)
            let size = text.size()
            text.draw(at: CGPoint(x: LineCardStyle.padding, y: rect.midY - size.height / 2))
        }
    }

    private func drawHeader() {
        let name = NSAttributedString(string: header.name, attributes: [.font: LineCardStyle.headerFont, .foregroundColor: NSColor.labelColor])
        let nameSize = name.size()
        let image = header.mark.flatMap { mark in
            NSImage(systemSymbolName: mark.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: LineCardStyle.markSize, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [mark.color])))
        }
        let markWidth = image.map { $0.size.width + LineCardStyle.chipGap } ?? 0
        let chip = CGRect(x: LineCardStyle.padding, y: LineCardStyle.padding + (LineCardStyle.headerHeight - LineCardStyle.chipHeight) / 2,
                          width: LineCardStyle.chipPadding * 2 + markWidth + ceil(nameSize.width), height: LineCardStyle.chipHeight)
        let path = NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2)
        LineCardStyle.chipFill.setFill()
        path.fill()
        LineCardStyle.chipEdge.setStroke()
        path.lineWidth = 1
        path.stroke()
        var x = chip.minX + LineCardStyle.chipPadding
        if let image {
            let size = image.size
            image.draw(in: CGRect(x: x, y: chip.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += size.width + LineCardStyle.chipGap
        }
        name.draw(at: CGPoint(x: x, y: chip.midY - nameSize.height / 2))
    }
}

/// A toggle's or a choice's line: what it says, drawn at its value's place, and the keys and clicks that press it. It takes the
/// keyboard; VoiceOver hears a checkbox or a pop-up button named for the line.
@MainActor
final class LineCardControl: NSView {
    var onKey: ((LineKey) -> Bool)?
    var onPress: (() -> Void)?
    var onFocus: (() -> Void)?
    var role: NSAccessibility.Role = .checkBox {
        didSet { setAccessibilityRole(role) }
    }
    /// What it says: "yes", "restrict".
    var value = "" {
        didSet {
            needsDisplay = true
            setAccessibilityValue(role == .checkBox ? (value == LineCardStyle.yes ? 1 : 0) as NSNumber : value as Any)
        }
    }
    /// Said faint: a choice with none held, its first option shown.
    var isFaint = false {
        didSet { needsDisplay = true }
    }
    /// Where its value is drawn from, in its own coordinates.
    var valueX: CGFloat = 0

    init(label: String) {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        superview?.needsDisplay = true
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        superview?.needsDisplay = true
        return resigned
    }

    /// Space and Return press it; the arrows, Tab and ⇧Tab, Escape, ⌘↑ and ⌘↩ are the card's.
    override func keyDown(with event: NSEvent) {
        guard let reading = KeyMeaning.Reading(event: event) else { return super.keyDown(with: event) }
        let line: LineKey?
        switch (reading.meaning, reading.modifiers) {
        case (.toggle, []), (.activate, []):
            if !event.isARepeat { onPress?() }
            return
        case (.up, []): line = .up
        case (.down, []): line = .down
        case (.up, [.command]): line = .end
        case (.next, _): line = .next
        case (.previous, _): line = .previous
        case (.back, _): line = .end
        case (.finish, _): line = .finish
        default: line = nil
        }
        guard let line, onKey?(line) == true else { return super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        _ = onKey?(.end)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = role == .checkBox ? LineCardStyle.valueFont : LineCardStyle.codeFont
        let text = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: isFaint ? NSColor.tertiaryLabelColor : NSColor.labelColor])
        let size = text.size()
        text.draw(at: CGPoint(x: valueX, y: bounds.midY - size.height / 2))
    }
}

/// How a row's card looks, view points: the card's own inks (it's on the card's bubble, not the paper), the kind's fonts.
@MainActor
enum LineCardStyle {
    static let width: CGFloat = 280
    static let padding: CGFloat = 12
    static let headerHeight: CGFloat = 26
    static let headerGap: CGFloat = 6
    static let lineHeight: CGFloat = 26
    static let labelWidth: CGFloat = 92
    static let chipHeight: CGFloat = 22
    static let chipPadding: CGFloat = 9
    static let chipGap: CGFloat = 5
    static let markSize: CGFloat = 11
    static let chipFill = NSColor.labelColor.withAlphaComponent(0.06)
    static let chipEdge = NSColor.separatorColor
    static let headerFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    static let labelFont = NSFont.systemFont(ofSize: 13)
    static let valueFont = NSFont.systemFont(ofSize: 13)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    /// The band behind the stop with the keyboard, as the row's is.
    static let band = NSColor.controlAccentColor.withAlphaComponent(0.16)
    static let bandInset: CGFloat = 6
    static let bandRadius: CGFloat = 4
    /// How far left of its value a control's line starts, for its band and its menu.
    static let focusInset: CGFloat = 4
    static let menuInset: CGFloat = 0
    static let menuDrop: CGFloat = 4
    /// Room after a field's text, so the caret at the end isn't cut.
    static let textSlack: CGFloat = 4
    static let yes = "yes"
    static let no = "no"

    /// What VoiceOver calls the card: "Details of customer_id".
    static func label(_ name: String) -> String { "Details of \(name)" }

    /// A toggle's or a choice's new state, as announced: "null yes".
    static func spoken(_ label: String, _ value: String) -> String { "\(label) \(value)" }

    /// A list's item: "notes, 2 of 3".
    static func item(_ label: String, _ number: Int, of count: Int) -> String { "\(label), \(number) of \(count)" }

    /// The kind's line look in the card's inks and sizes: its spans' pills keep their colors.
    static func lineStyle(from style: LineStyle) -> LineStyle {
        LineStyle(font: valueFont, codeFont: codeFont, ink: .labelColor, secondaryInk: .secondaryLabelColor, textInset: 0, trailingInset: 0,
                  gutterMiddle: 0, markSize: markSize, band: band, bandInset: bandInset)
    }
}
