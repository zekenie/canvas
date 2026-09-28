import Canvas
import DetailPanel
import Foundation
import LanguageModels
import SwiftUI
import Titles

/// The card's own tab: what it holds, in words and as JSON Schema.
public enum SchemaTab {}
extension SchemaTab: DetailTab {
    public static var title: String { "Schema" }
}

extension ShapeRegistrar where Definition == SchemaCardDefinition {
    /// The card's panel, its only editor: the header, where it's renamed (its `"title"`), and the
    /// Schema tab: the description (the prompt) over the JSON Schema, each rewritten from the other
    /// by `SchemaSync`, whose status shows under the side the person edited. Arrange comes from the
    /// panel itself.
    mutating func schemaPanel() {
        details(header: { $card in schemaHeader($card) }) {
            DetailSection("Description", in: SchemaTab.self) { $card in SchemaDescription(card: $card) }
            DetailSection("JSON Schema", in: SchemaTab.self) { $card in SchemaCode(card: $card) }
        }
    }
}

/// What the panel says about schema cards.
@MainActor
enum SchemaPanelText {
    static let untitled = "Untitled Schema"
    static let promptPlaceholder = "Describe what it holds: “a pet in my household”, or “email required, phone required, notes”"
    static let updatingSchema = "Updating schema…"
    static let updatingPrompt = "Updating description…"
    static let openSettings = "Open Settings…"
    static let retry = "Retry"

    /// Under the name: how many fields, or why there are none to count.
    static func subtitle(_ document: SchemaDocument) -> String {
        if document.error != nil { return "Invalid JSON" }
        guard document.isObject else { return "Not an object schema" }
        switch document.fields.count {
        case 0: return "No fields"
        case 1: return "1 field"
        case let count: return "\(count) fields"
        }
    }

    /// Under the JSON Schema while it isn't one; nil while it is.
    static func problem(_ document: SchemaDocument) -> String? {
        if let error = document.error {
            return "Line \(error.line), column \(error.column): \(error.message.prefix(1).lowercased() + error.message.dropFirst())."
        }
        return document.isObject ? nil : "A schema must be a JSON object."
    }
}

/// The name, which is the schema's `"title"`: renamed in place, which rewrites that member alone
/// (`setTitle`). It can't be while the text isn't a JSON object, nor while the model writes it.
/// Renaming is a write to the schema, so a name typed is one undo step ("Change Schema").
@MainActor
func schemaHeader(_ card: ShapeBinding<SchemaCard>) -> TitleHeader {
    let id = card.shape.id
    let document = SchemaReadings.reading(of: card.wrappedValue.schema, for: id).document
    let isUpdating = card.service(SchemaSync.self)?.status(of: id) == .updating(.schema)
    // Read from the text the last rename made, so a field typed ahead of the panel keeps it.
    let schema = card.schema
    return TitleHeader(Binding(get: { SchemaReadings.reading(of: schema.wrappedValue, for: id).document.title ?? "" },
                               set: { name in card.update(\.schema) { $0.setTitle(name) } }),
                       placeholder: SchemaPanelText.untitled, subtitle: SchemaPanelText.subtitle(document),
                       isEnabled: document.isObject && !isUpdating)
}

// The sections' commits hold the sync weakly: a text view that loses the keyboard as its window
// closes commits a turn later (`DetailTextArea`), after the board, its editor and its sync may
// have gone.

/// The prompt, and under it the sync's status when it's about the prompt (the schema being
/// written from it, or why it couldn't be).
struct SchemaDescription: View {
    @ShapeBinding var card: SchemaCard

    var body: some View {
        let sync = $card.service(SchemaSync.self), id = $card.shape.id
        let status = sync?.status(of: id) ?? .idle
        DetailTextArea($card.prompt, placeholder: SchemaPanelText.promptPlaceholder, onCommit: { [weak sync] in sync?.commit(id) })
            .detailUpdating(status == .updating(.prompt))
        SchemaSyncLine(status: status, under: .prompt, sync: sync, id: id)
    }
}

/// The JSON Schema as text, what's wrong with it while it isn't one, and the sync's status when
/// it's about the schema (the description being written from it, or why it couldn't be). What's
/// typed in it, keystroke after keystroke, is one undo step ("Change JSON Schema"), as the
/// description's is ("Change Description").
struct SchemaCode: View {
    @ShapeBinding var card: SchemaCard

    var body: some View {
        let sync = $card.service(SchemaSync.self), id = $card.shape.id
        let status = sync?.status(of: id) ?? .idle
        let schema = $card.schema
        DetailCodeEditor(Binding(get: { schema.wrappedValue }, set: { text in $card.update(\.schema) { $0.setSchema(text) } }),
                         coloring: { text in SchemaCodeColors.spans(in: text, for: id) }, onCommit: { [weak sync] in sync?.commit(id) })
            .detailUpdating(status == .updating(.schema))
        if let problem = SchemaPanelText.problem(SchemaReadings.reading(of: card.schema, for: id).document) {
            DetailStatusLine(DetailStatus(problem, tone: .error))
        }
        SchemaSyncLine(status: status, under: .schema, sync: sync, id: id)
    }
}

/// Where the sync is, under the side the person edited (`SchemaSyncStatus.source`): so it's under
/// the text they just committed, and in view whichever section is collapsed. Updating, with a
/// spinner (the side being written is dimmed and read-only), or why it failed, with what can be
/// done: Retry, and for want of a key Open Settings… too; nothing for a schema too long to write.
struct SchemaSyncLine: View {
    let status: SchemaSyncStatus
    let side: SchemaSide
    weak var sync: SchemaSync?
    let id: ShapeID

    init(status: SchemaSyncStatus, under side: SchemaSide, sync: SchemaSync?, id: ShapeID) {
        self.status = status
        self.side = side
        self.sync = sync
        self.id = id
    }

    var body: some View {
        if status.source == side {
            switch status {
            case .idle:
                EmptyView()
            case let .updating(writing):
                DetailStatusLine(DetailStatus(writing == .schema ? SchemaPanelText.updatingSchema : SchemaPanelText.updatingPrompt), isBusy: true)
            case let .failed(failure):
                DetailStatusLine(DetailStatus(failure.message, tone: .error), actions: actions(for: failure.remedy))
            }
        }
    }

    private func actions(for remedy: SchemaSyncFailure.Remedy) -> [DetailStatusAction] {
        let id = id
        let retry = DetailStatusAction(SchemaPanelText.retry) { [weak sync] in sync?.retry(id) }
        switch remedy {
        case .retry: return [retry]
        case .key: return [DetailStatusAction(SchemaPanelText.openSettings) { AnthropicSettingsView.showSettings() }, retry]
        case .editByHand: return []
        }
    }
}

/// The JSON Schema's colors in the code editor: `JSONReader.tokens`, a scan that never fails, so a
/// half-typed schema is colored as far as it goes. A member's name is a string followed by a colon.
enum SchemaCodeColors {
    /// Past this many bytes the text isn't colored: each keystroke scans it all.
    static let maxLength = 200_000

    /// The runs of the card `id`'s schema `text`, and where it stops being JSON, from the card's
    /// reading (which the card, its rules and the panel read too).
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
