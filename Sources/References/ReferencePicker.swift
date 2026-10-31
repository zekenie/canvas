import AppKit
import Canvas
import Mentions
import Publishing
import TextEditing

/// What a reference may name: the public shapes, of any board of the file. It's the scope the list
/// over the pill's field asks Mentions' candidates in (`MentionState.candidates(matching:in:for:)`),
/// so its ranking, recency and nearness are the `@` picker's.
public enum PublicShapes {}

extension PublicShapes: MentionScope {
    @MainActor public static func admits(_ shape: AnyShapeRecord, in registry: Registry) -> Bool {
        registry.isPublic(shape)
    }
}

/// A shape the list offers: what Mentions says of it, and the name of the board it's on when that
/// isn't the board shown (nil on it). Mentions' choice, which every list of shapes shows alike.
public typealias ReferenceChoice = MentionChoice

/// One row of the list over the pill's field: a shape that can be picked, the words as typed (the
/// last row while there's text), or the one row an empty list shows. Only the first two can be
/// highlighted and picked.
public enum ReferencePickerRow: Hashable, Sendable {
    case shape(ReferenceChoice)
    case words(String)
    case empty(String)
}

/// The list shown over a pill's field while it's typed into, headless, built on every caret list's
/// (`CaretList`, TextEditing's, which keeps the highlight and says what the keys do): the field
/// feeds it the text after each change (`setText`) and hands it the commands the keys send
/// (`perform`), and shows its list in a `CaretListWindow`.
///
/// What it lists is the public shapes the text matches (nothing typed: the recent picks and the
/// shapes nearby, without headers), ranked as the `@` picker ranks them, and, while there's text,
/// the words as typed, always last and set off by a line: `magnifyingglass` and the text. The first
/// shape is highlighted, or, when no shape is left, the words row is: the hand-off to natural
/// language (`isHandoff`), where Return commits the words. With nothing typed and no public shape in the
/// file, the list has one dimmed row saying so, never a blank one. A row's detail is the name of its
/// board when that isn't the board shown, or, when two rows are called alike, its kind and then that
/// board's name ("Note · Payments"). A pill that already stands for a shape (`current`) has that shape's
/// row highlighted while the text is still what the field opened with, so Return then keeps it, though
/// another shape is called alike and ranks above it.
@MainActor
public final class ReferencePicker {
    /// What's typed.
    public private(set) var text: String
    /// What it lists for the text, row for row as the list shows them.
    public private(set) var rows: [ReferencePickerRow] = []
    /// The list the picker shows: its rows as they're drawn and said, and the highlight.
    public let list = CaretList(metrics: ReferenceStyle.pickerMetrics)
    /// Called after the rows or the highlight change.
    public var onChange: (@MainActor () -> Void)?
    /// What the picker lists for a text.
    private let search: @MainActor (String) -> [ReferenceChoice]
    /// The shape the pill stands for and the text the field opened with, which the shape's row is
    /// highlighted for.
    private let current: (id: ShapeID, text: String)?

    /// A picker listing what `search` finds for each text.
    public init(text: String = "", current: (id: ShapeID, text: String)? = nil,
                search: @escaping @MainActor (String) -> [ReferenceChoice]) {
        self.text = text
        self.current = current
        self.search = search
        setRows(for: text)
        list.onChange = { [weak self] in self?.onChange?() }
    }

    /// A picker listing the public shapes of the file `state` is for, for the reference `owner` (whose
    /// place on the board nearness is measured from).
    public convenience init(state: ReferenceState, owner: ShapeID?, text: String = "", current: (id: ShapeID, text: String)? = nil) {
        self.init(text: text, current: current) { [weak state] text in state?.choices(matching: text, for: owner) ?? [] }
    }

    /// The index in `rows` of the highlighted row, always a shape's or the words'; nil when none can be picked.
    public var highlighted: Int? { list.highlighted }

    /// The highlighted row.
    public var highlightedRow: ReferencePickerRow? { highlighted.map { rows[$0] } }

    /// Whether only the words row is left: no public shape matches, so natural language is next.
    public var isHandoff: Bool {
        if rows.count == 1, case .words = rows[0] { true } else { false }
    }

    /// Lists what the text finds, the first shape highlighted (the words row when there's none).
    public func setText(_ text: String) {
        self.text = text
        setRows(for: text)
    }

    /// Highlights a row (the pointer's over it); a state row highlights nothing new.
    public func highlight(row index: Int) { list.highlight(row: index) }

    /// Does what a command the keys send does to the list, as every caret list does (`CaretList.perform`):
    /// ↑ ↓ wrap, Return and Tab pick the highlighted row, Escape closes.
    public func perform(_ command: Selector) -> (taken: Bool, action: CaretList.Action?) { list.perform(command) }

    // MARK: Rows

    private func setRows(for text: String) {
        let typed = !ReferenceEdits.isBlank(text)
        var rows = search(text).map { ReferencePickerRow.shape($0) }
        if typed {
            rows.append(.words(text))
        } else if rows.isEmpty {
            rows = [.empty(ReferenceStyle.noPublicShapes)]
        }
        self.rows = rows
        list.setRows(Self.listRows(rows))
        if let current, text == current.text,
           let index = rows.firstIndex(where: { if case .shape(let choice) = $0 { choice.candidate.id == current.id } else { false } }) {
            list.highlight(row: index)
        }
    }

    /// The rows as the list draws and says them: a shape's line is Mentions' (`MentionChoice.items`), and so is
    /// the words row (`MentionPicker.wordsItem`: a magnifier, and a line above it when shapes are listed).
    private static func listRows(_ rows: [ReferencePickerRow]) -> [CaretListRow] {
        var choices: [ReferenceChoice] = []
        for case .shape(let choice) in rows { choices.append(choice) }
        let items = MentionChoice.items(choices)
        var position = 0
        return rows.map { row in
            switch row {
            case .empty(let words): return .empty(words)
            case .words(let words):
                return .item(MentionPicker.wordsItem(words, separated: !choices.isEmpty))
            case .shape:
                position += 1
                return .item(items[position - 1])
            }
        }
    }
}

extension ReferenceState {
    /// The public shapes `text` finds, in the order the list shows them: Mentions' candidates in
    /// `PublicShapes` (nothing typed: the recent picks and those nearest `owner`; typed: the best
    /// matches). With nothing typed and none recent or near (the board shown holds none), the first
    /// public shapes of the file, so the list is never empty while one is there to pick.
    func choices(matching text: String, for owner: ShapeID?) -> [ReferenceChoice] {
        guard let mentions = editor.mentions else { return [] }
        var found = mentions.candidates(matching: text, in: PublicShapes.self, for: owner).all
        if found.isEmpty, ReferenceEdits.isBlank(text) { found = publicShapes(limit: ReferenceStyle.pickerRest) }
        return mentions.choices(found)
    }

    /// The first public shapes of the file that can be named: the root's, in board order, then each other
    /// board's (by the owner's id, so the same ones every time), any board the app can show.
    private func publicShapes(limit: Int) -> [MentionCandidate] {
        var found: [MentionCandidate] = []
        let registry = editor.registry
        func scan(_ document: CanvasDocument) {
            for record in document.shapes {
                guard found.count < limit else { return }
                guard registry.isPublic(record), let appearance = registry.mentionAppearance(of: record), !appearance.isPlaceholder,
                      editor.shape(inFile: record.id) != nil else { continue }
                found.append(MentionCandidate(id: record.id, appearance: appearance, isReadOnly: false, matched: []))
            }
        }
        let file = editor.file
        scan(file.root)
        for owner in file.children.keys.sorted(by: { $0.description < $1.description }) {
            if let document = file.children[owner] { scan(document) }
        }
        return found
    }
}
