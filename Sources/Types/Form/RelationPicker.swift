import AppKit
import Canvas
import Mentions
import TextEditing

// The list a relation row finds a note in while it is typed in: the notes that fit the row's other end, on any board of
// the file, ranked as the `@` picker ranks them (Mentions' candidates, over the set `RelationshipIndex` gives: the
// instances of the row's other types, through the chain, near and far), each line the name and, when it isn't the board
// shown, the board's, and `· will be made public` when the pick would do that (`FarVerdict`). It never filters by the
// board shown. A note with no title and no words is in it, named by its values, and one with nothing in it too
// (`listingUnnamed`): the row's list leaves out nothing that fits, so a note with something in it is never missed. A note a
// pick cannot reach (private, on a board that cannot change) is left out. Headless, as `ReferencePicker` is: a field feeds
// it the text and hands it the commands the keys send, and shows its list in a `CaretListWindow`. Its keys are
// `NotePicking`'s.
//
// A hub is a row with thousands of candidates, so the set is made once a commit (a slot array with no repeats and no note
// it cannot pick) and a keystroke that extends the query ranks what the last one matched, while that was all of it.

@MainActor
public final class RelationPicker: NotePicking {
    private let editor: CanvasEditor
    private let owner: ShapeID
    public let row: RelationshipRow
    /// The kinds of shape that draw rows: what an open side lists.
    private let kinds: Set<ShapeKind>
    /// What's typed.
    public private(set) var query = ""
    /// What it lists for the query, row for row as the list shows them.
    public private(set) var choices: [MentionChoice] = []
    /// The list the picker shows: its rows as they're drawn and said, and the highlight.
    public let list = CaretList(metrics: TypesStyle.relationPickerMetrics)

    /// The notes the row may name, made for the commit it was made at (`editor.revision`): no repeats, none it cannot pick,
    /// not the owner and not a note the row shows already. Nil: the other side is open, and any note of a kind that draws
    /// rows fits.
    private var instances: [ShapeID]?
    /// How many notes the picker holds to rank; nil for an open side. For the tests and the benchmark.
    public var held: Int? { instances?.count }
    /// What a pick of each of the notes that must be changed first says in its line (`public`), by note.
    private var needs: [ShapeID: String] = [:]
    /// Whether any note fits the other end at all, whoever has it already.
    private var anyFits = false
    private var seen: Int?
    /// An open side's, made for the commit: the notes the row names already, the verdicts on a pick, and what each note
    /// asked about was answered (can it be picked, and is it no type).
    private var open: (shown: Set<ShapeID>, verdicts: FarVerdicts, admitted: [ShapeID: Bool])?
    /// The last typed query and the notes it matched, while that was every one it matched (fewer than a list holds), and how
    /// many words it had.
    private var narrowed: (query: String, ids: [ShapeID], words: Int)?
    /// How many notes the last ranking read: what narrowing saves, for the tests and the benchmark.
    public private(set) var lastRanked = 0

    /// A picker listing the notes `owner` may name in `row`, nothing typed yet: the recent picks and the notes nearest it,
    /// then those on other boards.
    public init(editor: CanvasEditor, owner: ShapeID, row: RelationshipRow, kinds: Set<ShapeKind> = []) {
        self.editor = editor
        self.owner = owner
        self.row = row
        self.kinds = kinds
        setQuery("")
    }

    /// Lists for `text` again (each keystroke), the first choice highlighted. The set of notes is made again after a commit
    /// (a note given a type in the middle of a pick shows at the next keystroke).
    public func setQuery(_ text: String) {
        refresh()
        let previous = narrowed
        query = text
        guard let mentions = editor.mentions else {
            choices = []
            list.setRows([.empty(emptyWords(for: text))])
            return
        }
        let candidates: MentionCandidates
        if let instances {
            // A longer query matches among what the shorter one did, when that was all of it and the two have as many
            // words: a word more also names a container (`alpha` matches no Checkout, `alpha c` the one in Alpha).
            var among = instances
            var ranked: MentionCandidates?
            if Self.ranks(text), let previous, text.hasPrefix(previous.query), MentionMatcher.words(in: text) == previous.words {
                among = previous.ids
                let found = mentions.candidates(matching: text, in: AnyMentionable.self, for: owner, among: among, listingUnnamed: true)
                // A query the matcher forgave a typo in (its second pass, which reads every label) is ranked again over the whole
                // set: what the last query did not match may be a typo of this one.
                if found.forgave { among = instances } else { ranked = found }
            }
            candidates = ranked ?? mentions.candidates(matching: text, in: AnyMentionable.self, for: owner, among: among, listingUnnamed: true)
            lastRanked = among.count
        } else {
            // What a note is asked once a commit (`open`), not once a note a keystroke.
            let owner = owner
            candidates = mentions.candidates(matching: text, in: AnyMentionable.self, for: owner, kinds: kinds, listingUnnamed: true) { [self] id in
                id != owner && openAdmits(id)
            }
            lastRanked = kinds.count
        }
        narrowed = nil
        if Self.ranks(text), candidates.matches.count < MentionRanking.maxMatches {
            narrowed = (text, candidates.matches.map(\.id), candidates.words)
        }
        choices = mentions.choices(candidates.all)
        if choices.isEmpty {
            list.setRows([.empty(emptyWords(for: text))])
        } else {
            let verdicts = instances == nil ? FarVerdicts(editor) : nil
            // A line is the name and the board's, as board 5 panel 3 draws it: no kind's symbol. A note a pick makes public
            // says so after its board.
            list.setRows(zip(MentionChoice.items(choices), choices).map { item, choice in
                var line = item
                line.symbol = nil
                line.tint = nil
                let word = needs[choice.candidate.id] ?? {
                    if case .fulfils(let needs)? = verdicts?.verdict(of: choice.candidate.id) { needs } else { nil }
                }()
                if let word {
                    line.detail = [item.detail, TypesStyle.willBeMade(word)].compactMap { $0 }.joined(separator: " · ")
                    line.spoken += ", \(TypesStyle.willBeMade(word))"
                }
                return .item(line)
            })
        }
    }

    /// Whether a query ranks anything: one of only whitespace takes Mentions' empty-query path (recent and nearby, no matches),
    /// so what it answered is no ranking for a longer query to narrow.
    private static func ranks(_ text: String) -> Bool { text.contains { !$0.isWhitespace } }

    // MARK: The set

    /// Makes the set of notes again when a commit has changed anything since.
    private func refresh() {
        guard seen != editor.revision else { return }
        seen = editor.revision
        narrowed = nil
        needs = [:]
        open = nil
        guard let relationships = editor.relationships else {
            instances = []
            anyFits = false
            return
        }
        guard let fitting = relationships.instances(for: row) else {
            instances = nil
            anyFits = true
            open = (shownFar(), FarVerdicts(editor), [:])
            return
        }
        anyFits = !fitting.isEmpty
        let verdicts = FarVerdicts(editor)
        let shown = shownFar()
        var kept: [ShapeID] = []
        kept.reserveCapacity(fitting.count)
        for id in fitting where id != owner && !shown.contains(id) {
            switch verdicts.verdict(of: id) {
            case .cannot: continue
            case .fulfils(let word): needs[id] = word
            case .here, .reads: break
            }
            kept.append(id)
        }
        instances = kept
    }

    /// The notes the row names already.
    private func shownFar() -> Set<ShapeID> {
        guard let relationships = editor.relationships else { return [] }
        let replacing = row.rule.onlyOne
        var shown: Set<ShapeID> = []
        for relation in relationships.relations(of: owner, in: row) {
            if let id = relation.far.reading.offeredNoMore(replacing: replacing) { shown.insert(id) }
        }
        return shown
    }

    /// Whether an open side lists a note: not shown already, no type, and a pick of it can be made. Asked once a commit.
    private func openAdmits(_ id: ShapeID) -> Bool {
        guard var held = open else { return false }
        if held.shown.contains(id) { return false }
        if let known = held.admitted[id] { return known }
        let admitted = editor.shape(inFile: id)?[TypeSchemaProperty.self] == nil && held.verdicts.verdict(of: id) != .cannot
        open = nil
        held.admitted[id] = admitted
        open = held
        return admitted
    }

    // MARK: Words

    /// With nothing to list: `No Layer notes` only while no Layer exists, anywhere; else `No notes`; with text typed,
    /// `No matches`.
    private func emptyWords(for text: String) -> String {
        guard text.isEmpty else { return TypesStyle.noMatches }
        guard !anyFits, row.others.count == 1, let types = editor.types, case .live(let title?) = types.name(of: TypeLink(row.others[0])) else {
            return TypesStyle.noNotes(of: nil)
        }
        return TypesStyle.noNotes(of: title)
    }

    // MARK: Picking

    public func pickNote(row index: Int) -> ShapeID? {
        guard choices.indices.contains(index), let record = editor.shape(inFile: choices[index].candidate.id) else { return nil }
        editor.mentions?.didPick(record.id)
        return record.id
    }
}
