import AppKit
import Boards
import Canvas
import DetailPanel
import LanguageModels
import Mentions
import Queries
import Selection
import SwiftUI

/// The panel's header: what the reference stands for, as its pill says it, never renamed there: its
/// symbol (secondary, as every header's is), what it's called in the header's own type, and a line
/// under it (the kind and the board, or "Deleted", "Not available", "Not public"; for a dynamic one,
/// how many it found). It reads the reference's state, so a rename, a deletion, a change of publicness
/// or an answer arriving shows as it happens.
public struct ReferenceHeader: View {
    let id: ShapeID?
    let props: Reference
    let state: ReferenceState?

    /// What it says: from the state, or, with none, an empty pill's.
    public var content: ReferenceHeaderContent {
        state?.header(of: props, id: id) ?? ReferenceHeaderContent(symbol: ReferenceStyle.systemImage, title: ReferenceStyle.placeholder, subtitle: nil)
    }

    public var body: some View {
        let content = content
        DetailHeaderLabel(subtitle: content.subtitle, systemImage: content.symbol) { Text(content.title) }
    }
}

extension ShapeRegistrar where Definition == ReferenceDefinition {
    /// The reference's panel: its header; for one that names a shape, a plain Go to Original button,
    /// working on a locked reference too: it changes nothing, and is dimmed while
    /// there's nothing to go to (the shape is deleted, or not available); for one of words or a query,
    /// the Query section (the query, colored, read-only; a status line when there's something to say;
    /// Match ☐ All) and, while it found shapes, the Matches section.
    mutating func referencePanel() {
        details(header: { $reference in ReferenceHeader(id: $reference.shapeID, props: reference, state: $reference.service(ReferenceState.self)) }) {
            DetailSection(in: ReferenceTab.self, when: { $0.target != nil }) { _ in
                DetailCommandButton(command: .goToOriginal, systemImage: "arrow.up.forward.square")
            }
            .enabledWhileReadOnly()
            DetailSection(ReferenceStyle.querySection, in: ReferenceTab.self, id: "reference.query", when: { $0.mode == .dynamic }) { $reference in
                ReferenceQueryView(id: $reference.shapeID, props: reference, state: $reference.service(ReferenceState.self))
            }
            // The record's query is nil while words are typed: the draft's matches show as they arrive,
            // so whether there are any is `shownWhile`'s to say.
            DetailSection(ReferenceStyle.matchesSection, in: ReferenceTab.self, id: "reference.matches", when: { $0.mode == .dynamic }) { $reference in
                ReferenceMatchesView(id: $reference.shapeID, state: $reference.service(ReferenceState.self))
            }
            .shownWhile { shape, context in context.service(ReferenceState.self)?.matches(of: shape.id) != nil }
            .enabledWhileReadOnly()
        }
    }
}

// MARK: The Query section

/// What the Query section shows: the query (once there is one), and the line under it, when there's
/// something to say.
public struct ReferenceQueryContent: Equatable {
    public var query: String?
    public var status: ReferenceStatusLine?
    /// Whether the words stand for nothing until the person asks: the Interpret row, in the status
    /// line's place.
    public var offersInterpret: Bool
    /// Whether the words are being interpreted: the checkbox is disabled meanwhile.
    public var isInterpreting: Bool

    public init(query: String?, status: ReferenceStatusLine?, offersInterpret: Bool = false, isInterpreting: Bool = false) {
        self.query = query
        self.status = status
        self.offersInterpret = offersInterpret
        self.isInterpreting = isInterpreting
    }
}

/// A status line of the Query section: what it says, how (a warning, or neutral with a spinner), and
/// what it offers (Retry, Open Settings… for a missing key, or Make Public for what it found that
/// isn't).
public struct ReferenceStatusLine: Equatable {
    public enum Action: Equatable {
        case retry, openSettings, makePublic
    }

    public var text: String
    public var isWarning: Bool
    public var isBusy: Bool
    public var action: Action?
    /// Whether it offers Retry.
    public var retries: Bool { action == .retry }

    public init(text: String, isWarning: Bool, isBusy: Bool, action: Action?) {
        self.text = text
        self.isWarning = isWarning
        self.isBusy = isBusy
        self.action = action
    }
}

extension ReferenceState {
    /// What the Query section of a dynamic reference shows (observed: it changes as answers come).
    /// While its words are typed into, the query is the draft's, with its status and matches as they
    /// arrive.
    public func queryContent(of props: Reference, id: ShapeID) -> ReferenceQueryContent {
        let line: ReferenceStatusLine?
        let status = status(of: id)
        switch status {
        case .interpreting?:
            line = ReferenceStatusLine(text: ReferenceStyle.interpreting, isWarning: false, isBusy: true, action: nil)
        case .finding(slow: true)?:
            line = ReferenceStatusLine(text: ReferenceStyle.finding, isWarning: false, isBusy: true, action: nil)
        case .refused(let message)?:
            line = ReferenceStatusLine(text: message, isWarning: true, isBusy: false, action: nil)
        case .failed(let failure)?:
            line = ReferenceStatusLine(text: failure.message, isWarning: true, isBusy: false, action: failure.action)
        case .unavailable?:
            line = ReferenceStatusLine(text: ReferenceStyle.cantFind, isWarning: true, isBusy: false, action: nil)
        case .answered(let matches)? where matches.heldBack > 0:
            // What it found and doesn't stand for, as it isn't public, and the step that makes it so.
            line = ReferenceStatusLine(text: ReferenceStyle.notPublic(matches.heldBack), isWarning: false, isBusy: false, action: .makePublic)
        default:
            line = nil
        }
        // Words nobody has asked about stand for nothing: Interpret, unless they're being typed.
        let offers = status == nil && props.query == nil && offersInterpret(id)
        return ReferenceQueryContent(query: shown(props, id: id).query, status: line, offersInterpret: offers, isInterpreting: status == .interpreting)
    }

    /// Stands for every match, or the first: the panel's All and the menu's Match All and Match First,
    /// a step of their own. The width isn't refit: the room for the count is always there.
    public func setAll(_ all: Bool, of id: ShapeID) {
        guard let record = editor.document[id]?.typed(as: Reference.self), record.props.all != all else { return }
        editor.transact(all ? ReferenceStyle.matchAll : ReferenceStyle.matchFirst) { $0.update(id, as: Reference.self) { $0.props.all = all } }
    }
}

/// The query, read-only and colored as code is (one line per line, scrolling sideways, never
/// wrapped), the status line, and Match ☐ All.
struct ReferenceQueryView: View {
    let id: ShapeID
    let props: Reference
    let state: ReferenceState?

    /// What a status line offers: Retry asks again, Open Settings… is where a key is saved, Make Public
    /// makes public what the query found that isn't.
    private func actions(of line: ReferenceStatusLine) -> [DetailStatusAction] {
        switch line.action {
        case .retry?: [DetailStatusAction(ReferenceStyle.retry) { [state, id] in state?.retry(id) }]
        case .openSettings?: [DetailStatusAction(ReferenceStyle.openSettings) { _ = AnthropicSettingsView.showSettings() }]
        case .makePublic?: [DetailStatusAction(ReferenceStyle.makePublic) { [state, id] in state?.makeMatchesPublic(of: id) }]
        case nil: []
        }
    }

    var body: some View {
        let content = state?.queryContent(of: props, id: id) ?? ReferenceQueryContent(query: props.query, status: nil)
        VStack(alignment: .leading, spacing: ReferenceStyle.panelSpacing) {
            if let query = content.query {
                DetailCodeEditor(.constant(query), height: ReferenceStyle.queryBoxHeight, isEditable: false, coloring: ReferenceQueryColoring.spans)
            }
            if let line = content.status {
                DetailStatusLine(DetailStatus(line.text, tone: line.isWarning ? .warning : .neutral), isBusy: line.isBusy, actions: actions(of: line))
            } else if content.offersInterpret {
                DetailCommandButton(command: .interpretReference, systemImage: ReferenceStyle.interpretSymbol)
            }
            LabeledContent(ReferenceStyle.matchLabel) {
                DetailCheckbox(ReferenceStyle.allTitle, isOn: Binding(get: { props.all }, set: { [state, id] in state?.setAll($0, of: id) }))
            }
            .disabled(content.isInterpreting)
        }
    }
}

// MARK: The Matches section

/// A row of the Matches section: a shape a dynamic reference found.
public struct ReferenceMatchRow: Equatable, Identifiable {
    public var id: ShapeID
    public var symbol: String
    public var tint: NSColor?
    public var name: String
    /// Where it is, when that isn't the board shown: the containers it is inside, else its board's name.
    public var place: String?
    /// A first-match reference's rows after the first: what All would add.
    public var dimmed: Bool

    public init(id: ShapeID, symbol: String, tint: NSColor?, name: String, place: String?, dimmed: Bool) {
        self.id = id
        self.symbol = symbol
        self.tint = tint
        self.name = name
        self.place = place
        self.dimmed = dimmed
    }
}

extension ReferenceState {
    /// The Matches section's rows (at most `ReferenceStyle.matchRows`), and how many more there are.
    public func matchRows(of id: ShapeID) -> (rows: [ReferenceMatchRow], more: Int) {
        guard case .found(_, let found)? = state(of: id) else { return ([], 0) }
        var rows: [ReferenceMatchRow] = []
        for (index, match) in found.ids.prefix(ReferenceStyle.matchRows).enumerated() {
            guard let record = editor.shape(inFile: match), let appearance = editor.mentionAppearance(of: record) else { continue }
            rows.append(ReferenceMatchRow(id: match, symbol: appearance.systemImage, tint: appearance.tint, name: appearance.label, place: place(ofShape: match),
                                          dimmed: !found.all && index > 0))
        }
        return (rows, found.count - rows.count)
    }

    /// A click on a match goes to it, as following a mention of it does.
    public func follow(match id: ShapeID) {
        editor.mentions?.follow(id)
    }

    /// The pointer on a match's row hovers it on the canvas, if it's on the board shown.
    func hover(match id: ShapeID) {
        guard editor.document[id] != nil else { return }
        editor.hovered = id
    }

    func endHover(match id: ShapeID) {
        if editor.hovered == id { editor.hovered = nil }
    }
}

/// The matches, a row each, then how many more there are.
struct ReferenceMatchesView: View {
    let id: ShapeID
    let state: ReferenceState?

    var body: some View {
        if let state {
            let (rows, more) = state.matchRows(of: id)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    Button { state.follow(match: row.id) } label: {
                        DetailShapeRow(symbol: row.symbol, tint: row.tint, name: row.name, detail: row.place, dimmed: row.dimmed)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
                    .onHover { inside in
                        if inside { state.hover(match: row.id) } else { state.endHover(match: row.id) }
                    }
                    .onDisappear { state.endHover(match: row.id) }
                }
                if more > 0 {
                    Text(ReferenceStyle.more(more))
                        .font(.system(size: ReferenceStyle.captionSize))
                        .foregroundStyle(.secondary)
                        .padding(.leading, ReferenceStyle.moreIndent)
                }
            }
        }
    }
}

// MARK: Coloring a query

/// A query's runs as code is colored (`DetailCodeSpan`): a kind or an attribute's name as a name,
/// a quoted string as a string, a number as a number, a `:word` as a keyword, and a string left open
/// as what doesn't belong. A scan, not a parse: asked of the whole text as it's shown.
enum ReferenceQueryColoring {
    @MainActor static func spans(_ text: String) -> [DetailCodeSpan] {
        let units = Array(text.utf16)
        var spans: [DetailCodeSpan] = []
        var index = 0
        func isLetter(_ unit: UInt16) -> Bool {
            (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit > 127
        }
        func continues(_ unit: UInt16) -> Bool { isLetter(unit) || (48...57).contains(unit) || unit == 45 }
        while index < units.count {
            let unit = units[index]
            if unit == 34 || unit == 39 {
                let start = index
                index += 1
                while index < units.count, units[index] != unit {
                    if units[index] == 92 { index += 1 }
                    index += 1
                }
                let closed = index < units.count
                index = min(index + 1, units.count)
                spans.append(DetailCodeSpan(closed ? .string : .invalid, NSRange(location: start, length: index - start)))
            } else if unit == 58 {
                let start = index
                index += 1
                while index < units.count, continues(units[index]) { index += 1 }
                spans.append(DetailCodeSpan(.keyword, NSRange(location: start, length: index - start)))
            } else if isLetter(unit) {
                let start = index
                while index < units.count, continues(units[index]) { index += 1 }
                spans.append(DetailCodeSpan(.name, NSRange(location: start, length: index - start)))
            } else if (48...57).contains(unit) {
                let start = index
                while index < units.count, continues(units[index]) || units[index] == 46 { index += 1 }
                spans.append(DetailCodeSpan(.number, NSRange(location: start, length: index - start)))
            } else {
                index += 1
            }
        }
        return spans
    }
}
