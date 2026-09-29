import Canvas
import DetailPanel
import Foundation
import LanguageModels
import SwiftUI
import Titles
import Validation

/// The card's own tab: its JSON Schema.
public enum SchemaTab {}
extension SchemaTab: DetailTab {
    public static var title: String { "Schema" }
}

extension ShapeRegistrar where Definition == SchemaCardDefinition {
    /// The card's panel, where its schema is written: the header, where it's renamed (its
    /// `"title"`), and the Schema tab, its JSON, which `SchemaSync` rewrites from the description
    /// typed on the card, and the description from, with the sync's status under it. Arrange comes
    /// from the panel itself.
    mutating func schemaPanel() {
        details(header: { $card in schemaHeader($card) }) {
            DetailSection("JSON", in: SchemaTab.self) { $card in SchemaCode(card: $card) }
        }
    }
}

/// What the panel says about schema cards.
@MainActor
enum SchemaPanelText {
    static let updatingSchema = "Updating schema…"
    static let updatingPrompt = "Updating description…"
    static let openSettings = "Open Settings…"
    static let retry = "Retry"

    /// Under the name: how many top-level fields the schema has, as its row's badge counts them;
    /// nothing for none.
    static func subtitle(_ shown: SchemaDocument) -> String? {
        switch shown.fields.count {
        case 0: nil
        case 1: "1 field"
        case let count: "\(count) fields"
        }
    }
}

/// The name, which is the schema's `"title"`, as the card shows it: renamed in place, which
/// rewrites that member alone (`setTitle`). Not while the text isn't a JSON object (the name shows,
/// as the card's last reading has it, but takes no typing), nor while the model writes it (dimmed).
/// Renaming is a write to the schema, so a name typed is one undo step ("Change Schema").
@MainActor
func schemaHeader(_ card: ShapeBinding<SchemaCard>) -> TitleHeader {
    let id = card.shape.id
    let reading = SchemaReadings.reading(of: card.wrappedValue.schema.text, for: id)
    let isUpdating = card.service(SchemaSync.self)?.status(of: id) == .updating(.schema)
    // Read from the text the last rename made, so a field typed ahead of the panel keeps it.
    let schema = card.schema
    return TitleHeader(Binding(get: { SchemaReadings.reading(of: schema.wrappedValue.text, for: id).shown.title ?? "" },
                               set: { name in card.update(\.schema) { $0.setTitle(name) } }),
                       placeholder: SchemaCard.untitled, subtitle: SchemaPanelText.subtitle(reading.shown),
                       isEnabled: !isUpdating, isRenamable: reading.document.isObject)
}

// The section's commit holds the sync weakly: a text view that loses the keyboard as its window
// closes commits a turn later (`DetailCodeEditor`), after the board, its editor and its sync may
// have gone.

/// The JSON Schema as text, which ⌃Space completes (`SchemaCompletions`: a `$ref` to another card in
/// the file too, by its name); under it, what Validation finds wrong with it (in its words, each in
/// its tone), and the sync's status, whichever side it writes: the schema from the description typed
/// on the card, or the description from this.
/// What's typed in it, keystroke after keystroke, picks included, is one undo step ("Change JSON").
/// While its list is open the sync's idle wait waits too (`SchemaSync.completing`): the person is
/// still choosing.
struct SchemaCode: View {
    @ShapeBinding var card: SchemaCard

    var body: some View {
        let sync = $card.service(SchemaSync.self), id = $card.shape.id
        let status = sync?.status(of: id) ?? .idle
        DetailCodeEditor($card.schema.text,
                         coloring: { text in SchemaCodeColors.spans(in: text, for: id) },
                         completions: { [weak sync] text, caret in
                             SchemaCompletions.completions(in: text, at: caret) { sync?.referenceTargets(from: id) ?? [] }.map(DetailCodeCompletions.init)
                         },
                         onCompleting: { [weak sync] isCompleting in sync?.completing(id, isCompleting) },
                         onCommit: { [weak sync] in sync?.commit(id) })
            .detailUpdating(status == .updating(.schema))
        let issues = SchemaReadings.reading(of: card.schema.text, for: id).issues
        ForEach(issues.indices, id: \.self) { i in
            DetailStatusLine(DetailStatus(issues[i].message, tone: issues[i].severity == .error ? .error : .warning))
        }
        SchemaSyncLine(status: status, sync: sync, id: id)
    }
}

/// Where the sync is, under the JSON: updating, with a spinner (the side being written, the JSON
/// or the card's description, is dimmed and read-only), or why it failed (the warning's tone: red
/// is the schema's own errors), with what can be done: Retry, or for want of a key Open Settings…
/// (saving one there tries again by itself); nothing for a schema too long to rewrite.
struct SchemaSyncLine: View {
    let status: SchemaSyncStatus
    weak var sync: SchemaSync?
    let id: ShapeID

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case let .updating(writing):
            DetailStatusLine(DetailStatus(writing == .schema ? SchemaPanelText.updatingSchema : SchemaPanelText.updatingPrompt), isBusy: true)
        case let .failed(failure):
            DetailStatusLine(DetailStatus(failure.message, tone: .warning), actions: actions(for: failure.remedy))
        }
    }

    private func actions(for remedy: SchemaSyncFailure.Remedy) -> [DetailStatusAction] {
        let id = id
        switch remedy {
        case .retry: return [DetailStatusAction(SchemaPanelText.retry) { [weak sync] in sync?.retry(id) }]
        case .key: return [DetailStatusAction(SchemaPanelText.openSettings) { AnthropicSettingsView.showSettings() }]
        case .editByHand: return []
        }
    }
}

/// The card's completions as the code editor lists them: the same candidates, in the same order,
/// every range already in UTF-16 (`SchemaCompletions`); the editor matches them against the query.
extension DetailCodeCompletions {
    init(_ completions: JSONCompletions) {
        self.init(range: NSRange(location: completions.range.lowerBound, length: completions.range.count), query: completions.query,
                  items: completions.items.map { item in
                      DetailCodeCompletion(label: item.label, detail: item.detail, insert: item.insert,
                                           selection: NSRange(location: item.selection.lowerBound, length: item.selection.count),
                                           reopens: item.reopens, isRelevant: item.isRelevant)
                  })
    }
}

/// The JSON Schema's colors in the code editor: `JSONReader.tokens`, a scan that never fails, so a
/// half-typed schema is colored as far as it goes. A member's name is a string followed by a colon.
enum SchemaCodeColors {
    /// Past this many bytes the text isn't colored: each keystroke scans it all.
    static let maxLength = 200_000

    /// The runs of the card `id`'s schema `text`, and where it stops being JSON, from the card's
    /// reading (which its name, its row, its rules, the panel and the sync read too).
    @MainActor
    static func spans(in text: String, for id: ShapeID) -> [DetailCodeSpan] {
        guard text.utf8.count <= maxLength else { return [] }
        return spans(in: text, error: SchemaReadings.reading(of: text, for: id).document.error)
    }

    /// The runs of `text`; the token where `error` is (where the text stops being JSON: a stray
    /// comma's next token, say) marked `.invalid`, unless it's at the end (a text still being typed).
    static func spans(in text: String, error: JSONSyntaxError? = nil) -> [DetailCodeSpan] {
        let utf8 = Array(text.utf8)
        guard utf8.count <= maxLength else { return [] }
        let tokens = JSONReader.tokens(in: text)
        let utf16 = UTF16Offsets(text, utf8Count: utf8.count)
        var spans: [DetailCodeSpan] = []
        spans.reserveCapacity(tokens.count / 2)
        for (i, token) in tokens.enumerated() {
            let role: DetailCodeSpan.Role
            switch token.kind {
            case .string: role = i + 1 < tokens.count && tokens[i + 1].kind == .colon ? .name : .string
            case .number: role = .number
            case .literal: role = .keyword
            case .invalid: role = .invalid
            case .openBrace, .closeBrace, .openBracket, .closeBracket, .colon, .comma: continue
            }
            let start = utf16[token.range.lowerBound], end = utf16[token.range.upperBound]
            spans.append(DetailCodeSpan(role, NSRange(location: start, length: end - start)))
        }
        if let error, let token = tokens.first(where: { $0.range.contains(error.offset) }) {
            let start = utf16[token.range.lowerBound], end = utf16[token.range.upperBound]
            spans.append(DetailCodeSpan(.invalid, NSRange(location: start, length: end - start)))
        }
        return spans
    }

    /// UTF-8 offsets as UTF-16 ones (`NSString`'s): the same while the text is ASCII, as JSON
    /// mostly is; else counted once, a scalar at a time (an offset inside one counts as its start).
    struct UTF16Offsets {
        private let table: [Int]?

        init(_ text: String, utf8Count: Int) {
            guard utf8Count != text.utf16.count else {
                table = nil
                return
            }
            var table = [Int](repeating: 0, count: utf8Count + 1)
            var utf8 = 0, utf16 = 0
            for scalar in text.unicodeScalars {
                let width = UTF8.width(scalar)
                for k in 0..<width { table[utf8 + k] = utf16 }
                utf8 += width
                utf16 += UTF16.width(scalar)
            }
            table[utf8Count] = utf16
            self.table = table
        }

        subscript(offset: Int) -> Int { table?[offset] ?? offset }
    }
}
