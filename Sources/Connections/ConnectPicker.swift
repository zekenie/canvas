import AppKit
import Canvas
import Draw
import Mentions
import TextEditing
import Topology

// What ⌘L lists on one shape: every shape in the file it can be connected to, on any board, ranked as the `@` picker ranks them
// (Mentions' catalog: `candidates(matching:in:for:kinds:listingUnnamed:admitting:)`), each line the shape's name and where it is
// ("shop", "archive") and `· will be made public` when the pick would do that (`FarVerdict`), and "Itself" last. Headless, as
// `RelationPicker` is: the host feeds it the text and shows its list in a `CaretListWindow`.
//
// The kinds it lists are the ones the port table can join the source to, directly or through the pill that stands for a shape of
// another board (a pill has the ports of what it stands for); a pick the source's kind does not admit (`ConnectPicks`), a shape the
// source holds or is held by (`mayConnect`) and one that cannot be reached (`FarVerdict.cannot`) are left out. Asked once a commit,
// not once a shape a keystroke.

@MainActor
public final class ConnectPicker {
    /// One row of the list: a shape (and what its pick would make of it first, in a word), Itself, or the one row an empty list shows.
    public enum Row: Hashable, Sendable {
        case shape(MentionChoice, needs: String?)
        case itself
        case empty(String)
    }

    private let editor: CanvasEditor
    /// The shape the picker was opened on.
    public let source: ShapeID
    /// The kinds of shape it lists.
    public let kinds: Set<ShapeKind>
    /// Whether the connector can join the source to itself: Itself is listed.
    public let canLoop: Bool
    /// What's typed.
    public private(set) var query = ""
    /// What it lists for the query, row for row as the list shows them.
    public private(set) var rows: [Row] = []
    /// The list the picker shows: its rows as they're drawn and said, and the highlight.
    public let list = CaretList(metrics: ConnectionsStyle.pickerMetrics)

    /// What was asked once for the commit it was made at (`editor.revision`): the verdict on a pick of each shape.
    private var seen: Int?
    private var verdicts: FarVerdicts?
    private var context: ShapeContext?
    private var admitted: [ShapeID: FarVerdict?] = [:]

    /// What the connector can join `source` to: the kinds of shape, and whether itself. Nil where there is nothing to pick for it:
    /// nothing makes connections, or it ends nowhere (a pill that stands for nothing), or it joins no kind of shape and not itself. A kind with ports only on its rows (a table's keys) has none on its sides: it joins
    /// the other kinds with none, as it did before it had any.
    static func reach(of source: ShapeID, in editor: CanvasEditor) -> (kinds: Set<ShapeKind>, loops: Bool)? {
        guard editor.registry.drawsConnections, let record = editor.document[source], let ports = editor.service(PortState.self),
              editor.registry.canConnect(source, in: editor.shapeContext), let standing = ports.standingKinds(of: record) else { return nil }
        let registry = editor.registry
        let connector = registry.connectorKind
        let standIns = registry.standIns.kinds
        func joins(_ kind: ShapeKind) -> Bool {
            registry.connectionChannel(from: record.kind, fromStandingFor: standing, to: kind) != nil
                || (!registry.hasPorts(record.kind, standingFor: standing, onParts: false) && !registry.hasPorts(kind, onParts: false))
        }
        let kinds = Set(registry.kinds.filter { $0 != connector && !standIns.contains($0) && joins($0) })
        // The connector can join it to itself where it can join its kind to its kind, and the kind admits it.
        let loops = joins(record.kind) && editor.connectPicksAdmit(from: source, to: source)
        return kinds.isEmpty && !loops ? nil : (kinds, loops)
    }

    /// A picker for `source`, a shape of the board shown; nil where there is nothing to pick for it (`reach`).
    public init?(editor: CanvasEditor, source: ShapeID) {
        guard let reach = Self.reach(of: source, in: editor) else { return nil }
        self.editor = editor
        self.source = source
        kinds = reach.kinds
        canLoop = reach.loops
        setQuery("")
    }

    /// Lists for `text` again (each keystroke), the first row highlighted. The set is judged again after a commit.
    public func setQuery(_ text: String) {
        relist(text, keepingHighlight: false)
    }

    /// Lists for `text` again after a commit: the set is judged anew, and the highlight stays on the shape it was on while that
    /// shape is still listed (a pick is what the person saw highlighted), else it is the first row.
    func relistAfterCommit(_ text: String) {
        relist(text, keepingHighlight: true)
    }

    private func relist(_ text: String, keepingHighlight: Bool) {
        let held = keepingHighlight ? list.highlighted.flatMap { target(row: $0) } : nil
        listFor(text)
        if let held, let row = rows.indices.first(where: { target(row: $0) == held }) { list.highlight(row: row) }
    }

    private func listFor(_ text: String) {
        refresh()
        query = text
        guard let mentions = editor.mentions else {
            rows = canLoop ? [.itself] : [.empty(ConnectionsStyle.noShapes)]
            list.setRows(Self.listRows(rows, choices: []))
            return
        }
        let source = source
        let found = mentions.candidates(matching: text, in: AnyMentionable.self, for: source, kinds: kinds, listingUnnamed: true) { [self] id in
            admits(id)
        }
        let choices = mentions.choicesNamingBoardShown(found.all)
        let typed = text.contains { !$0.isWhitespace }
        var rows: [Row] = choices.map { choice in
            if case .fulfils(let needs)? = admitted[choice.candidate.id] { .shape(choice, needs: needs) } else { .shape(choice, needs: nil) }
        }
        // Itself is last while anything is listed, or nothing is typed: a typed word that finds nothing leaves the list empty, so a
        // Return on it makes no loop.
        if canLoop, !rows.isEmpty || !typed { rows.append(.itself) }
        if rows.isEmpty { rows = [.empty(typed ? ConnectionsStyle.noMatches : ConnectionsStyle.noShapes)] }
        self.rows = rows
        list.setRows(Self.listRows(rows, choices: choices))
    }

    // MARK: The set

    private func refresh() {
        guard seen != editor.revision else { return }
        seen = editor.revision
        verdicts = FarVerdicts(editor)
        context = editor.shapeContext
        admitted = [:]
    }

    /// Whether the list offers a shape: not the source, a pick its kind admits, not one the source holds or is held by, and one that
    /// can be reached from the board shown.
    private func admits(_ id: ShapeID) -> Bool {
        if id == source { return false }
        if let known = admitted[id] { return known != .cannot }
        var verdict: FarVerdict = .cannot
        if editor.connectPicksAdmit(from: source, to: id) {
            if editor.document[id] != nil {
                verdict = context?.mayConnect(source, id) == false ? .cannot : .here
            } else if let verdicts {
                verdict = verdicts.verdict(of: id)
            }
        }
        admitted[id] = verdict
        return verdict != .cannot
    }

    // MARK: The rows

    /// The rows as the list draws and says them: a shape's line is Mentions' (`MentionChoice.items`), with what a pick makes of it
    /// first after its place; Itself last, set off by a line.
    private static func listRows(_ rows: [Row], choices: [MentionChoice]) -> [CaretListRow] {
        let items = MentionChoice.items(choices)
        var position = 0
        return rows.map { row in
            switch row {
            case .empty(let words): return .empty(words)
            case .itself:
                return .item(CaretListItem(ConnectionsStyle.itself, symbol: ConnectionsStyle.itselfSymbol, separated: !choices.isEmpty,
                                           spoken: ConnectionsStyle.itself))
            case .shape(_, let needs):
                var line = items[position]
                position += 1
                if let needs {
                    let words = FarVerdict.willBeMade(needs)
                    line.detail = [line.detail, words].compactMap { $0 }.joined(separator: " · ")
                    line.place = nil
                    line.spoken += ", \(words)"
                }
                return .item(line)
            }
        }
    }

    /// The shape a row picks: nil for a row that is no pick. Itself is the source.
    public func target(row index: Int) -> ShapeID? {
        guard rows.indices.contains(index) else { return nil }
        switch rows[index] {
        case .shape(let choice, _): return choice.candidate.id
        case .itself: return source
        case .empty: return nil
        }
    }

    /// Pressed on a row: the shape, and that it counts among the recent picks (a pick of Itself counts for none).
    public func pick(row index: Int) -> ShapeID? {
        guard let target = target(row: index) else { return nil }
        if target != source { editor.mentions?.didPick(target) }
        return target
    }
}

extension ConnectionsStyle {
    /// The picker's field: its width (the list's), its height, the space round its text, and its text.
    static let pickerFieldWidth: CGFloat = 280
    static let pickerFieldHeight: CGFloat = 28
    static let pickerInset: CGFloat = 8
    static let pickerLeadGap: CGFloat = 6
    static let pickerFont = NSFont.systemFont(ofSize: 13)
    /// The faint lead before what's typed.
    static let lead = "→"
    /// The list's size: wide as the field, as many rows as Jump To's smaller list.
    static let pickerMetrics = CaretListMetrics(width: pickerFieldWidth, rowHeight: 28, rowsShown: 8, offset: 4)
    /// The last row: the shape itself.
    static let itself = "Itself"
    static let itselfSymbol = "arrow.uturn.right.circle"
    static let noShapes = "No shapes"
    static let noMatches = "No matches"
    /// What VoiceOver calls the field and its list.
    static let fieldLabel = "Connect to"
    static let listLabel = "Connect to"
    /// What VoiceOver calls the card: "Connect from order_items".
    static func cardLabel(_ name: String) -> String { name.isEmpty ? "Connect" : "Connect from \(name)" }
}
