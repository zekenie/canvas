import Canvas
import Colors
import DetailPanel
import Foundation
import LanguageModels
import Selection
import SwiftUI
import Validation

/// A type's own tab: its JSON Schema.
public enum TypeSchemaTab {}
extension TypeSchemaTab: DetailTab {
    public static var title: String { "Schema" }
}

/// The Types tab of a shape that is some: each type it is, in the order of its list.
public enum TypesTab {}
extension TypesTab: DetailTab {
    public static var title: String { "Types" }
    /// A feature tab a horizontal adds to the kinds that opt into it.
    public static var order: Int { 50 }
}

/// What the panel says about types.
@MainActor
enum TypePanelText {
    static let updatingSchema = "Updating schema…"
    static let updatingWords = "Updating text…"
    static let openSettings = "Open Settings…"
    static let retry = "Retry"

    /// How many top-level fields a schema has, as a `$ref`'s completion says it; nothing for none.
    static func subtitle(_ shown: SchemaDocument) -> String? {
        switch shown.fields.count {
        case 0: nil
        case 1: "1 field"
        case let count: "\(count) fields"
        }
    }
}

/// The Schema tab of every type (every shape that holds a schema, whatever its kind): its JSON,
/// which `TypeSync` rewrites from the shape's words, and the words from, with its issues and the
/// sync's status under it. The shape's header (its title, the type's name) is its kind's. The Types
/// tab holds the shape's types, then its Fields (`FieldsPanel.swift`).
@MainActor
func registerTypePanel(into registrar: inout PluginRegistrar) {
    registrar.details(of: TypeSchemaProperty.self) {
        DetailSection("JSON", in: TypeSchemaTab.self) { $schema in TypeSchemaCode(schema: $schema) }
    }
    // Every shape that is some, whatever its kind: its types, in order, each a row that goes to the
    // type, and a minus that takes the shape out of it. Going to a type changes nothing, so the rows
    // work on a shape that can't change; the minus doesn't.
    registrar.details(of: IsAProperty.self) {
        DetailSection(in: TypesTab.self, id: "types") { $types in TypesList(types: $types) }
            .enabledWhileReadOnly()
    }
}

// The section's commit holds the sync weakly: a text view that loses the keyboard as its window
// closes commits a turn later (`DetailCodeEditor`), after the board, its editor and its sync may
// have gone.

/// A type's JSON Schema as text, which ⌃Space completes (`TypeCompletions`: a `$ref` to another type
/// in the file too, by its name); under it, what Validation finds wrong with it (in its words, each in
/// its tone), and the sync's status, whichever side it writes: the schema from the shape's words, or
/// the words from this. What's typed in it, keystroke after keystroke, picks included, is one undo
/// step ("Change JSON"). While its list is open the sync's idle wait waits too
/// (`TypeSync.completing`): the person is still choosing.
struct TypeSchemaCode: View {
    @ShapeBinding var schema: SchemaText

    var body: some View {
        let sync = $schema.service(TypeSync<TypeSchemaProperty>.self), types = $schema.service(TypeIndex.self), id = $schema.shapeID
        let book = $schema.service(ColorBook.self)
        let status = sync?.status(of: id) ?? .idle
        SchemaCodeEditor(text: $schema.text, for: id, isUpdating: status == .updating(.schema),
                         types: { [weak types] in types?.referenceTargets(from: id) ?? [] },
                         colors: { [weak book] in (book?.names ?? BuiltInColors.all).map(TypeCompletions.color) },
                         onCompleting: { [weak sync] isCompleting in sync?.completing(id, isCompleting) },
                         onCommit: { [weak sync] in sync?.commit(id) })
        let issues = SchemaReadings.reading(of: schema.text, for: id).issues
        ForEach(issues.indices, id: \.self) { i in
            DetailStatusLine(DetailStatus(issues[i].message, tone: issues[i].severity == .error ? .error : .warning))
        }
        TypeSyncLine(status: status, sync: sync, id: id)
    }
}

/// A JSON Schema's code editor, as a type's Schema tab has it: colored by `JSONReader.tokens` (the
/// token where it stops being JSON marked, from the shape's reading), completed by ⌃Space
/// (`TypeCompletions`, `types` the other types a `$ref` can point to, `colors` the colors a `$color`
/// can be, `extra` what else a place takes), and dimmed and read-only while the model writes it
/// (`isUpdating`). For any schema kept as a shape's text.
public struct SchemaCodeEditor: View {
    @Binding var text: String
    let id: ShapeID
    let isUpdating: Bool
    let types: @MainActor () -> [JSONCompletionOffer]
    let colors: @MainActor () -> [JSONCompletionOffer]
    let extra: @Sendable (JSONCompletionPlace) -> [JSONCompletionOffer]
    let onCompleting: (@MainActor (Bool) -> Void)?
    let onCommit: (@MainActor () -> Void)?

    public init(text: Binding<String>, for id: ShapeID, isUpdating: Bool = false, types: @escaping @MainActor () -> [JSONCompletionOffer] = { [] },
                colors: @escaping @MainActor () -> [JSONCompletionOffer] = { BuiltInColors.all.map(TypeCompletions.color) },
                extra: @escaping @Sendable (JSONCompletionPlace) -> [JSONCompletionOffer] = { _ in [] },
                onCompleting: (@MainActor (Bool) -> Void)? = nil, onCommit: (@MainActor () -> Void)? = nil) {
        _text = text
        self.id = id
        self.isUpdating = isUpdating
        self.types = types
        self.colors = colors
        self.extra = extra
        self.onCompleting = onCompleting
        self.onCommit = onCommit
    }

    public var body: some View {
        let id = id, types = types, colors = colors, extra = extra
        DetailCodeEditor($text,
                         coloring: { text in SchemaCodeColors.spans(in: text, for: id) },
                         completions: { text, caret in
                             TypeCompletions.completions(in: text, at: caret, types: types, colors: colors, extra: extra).map(DetailCodeCompletions.init)
                         },
                         onCompleting: onCompleting, onCommit: onCommit)
            .detailUpdating(isUpdating)
    }
}

/// Where the sync is, under the JSON: updating, with a spinner (the side being written, the JSON or
/// the shape's words, is dimmed and read-only), or why it failed (the warning's tone: red is the
/// schema's own errors), with what can be done: Retry, or for want of a key Open Settings… (saving
/// one there tries again by itself); nothing for a schema too long to rewrite.
struct TypeSyncLine: View {
    let status: TypeSyncStatus
    weak var sync: TypeSync<TypeSchemaProperty>?
    let id: ShapeID

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case let .updating(writing):
            DetailStatusLine(DetailStatus(writing == .schema ? TypePanelText.updatingSchema : TypePanelText.updatingWords), isBusy: true)
        case let .failed(failure):
            DetailStatusLine(DetailStatus(failure.message, tone: .warning), actions: actions(for: failure.remedy))
        }
    }

    private func actions(for remedy: TypeSyncFailure.Remedy) -> [DetailStatusAction] {
        let id = id
        switch remedy {
        case .retry: return [DetailStatusAction(TypePanelText.retry) { [weak sync] in sync?.retry(id) }]
        case .key: return [DetailStatusAction(TypePanelText.openSettings) { AnthropicSettingsView.showSettings() }]
        case .editByHand: return []
        }
    }
}

/// A schema's completions as the code editor lists them: the same candidates, in the same order,
/// every range already in UTF-16 (`TypeCompletions`); the editor matches them against the query.
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


/// The types a shape is, one row each.
struct TypesList: View {
    @ShapeBinding var types: [TypeLink]

    var body: some View {
        let index = $types.service(TypeIndex.self), owner = $types.shapeID
        ForEach(types, id: \.shape) { link in TypesRow(link: link, owner: owner, index: index) }
    }
}

/// One type: its title, live (dimmed, with the last title it was known by, once it's gone), a click
/// on it goes there, and the minus at its end takes the shape out of it (one step, Remove Type).
struct TypesRow: View {
    let link: TypeLink
    let owner: ShapeID
    let index: TypeIndex?

    var body: some View {
        let name = index?.name(of: link) ?? .missing(lastKnown: nil)
        let editor = index?.editor
        let isGone = editor?.file.record(link.shape) == nil, isMissing = if case .missing = name { true } else { false }
        HStack(spacing: 2) {
            Button {
                let type = link.shape
                _ = editor?.scheduler.schedule(after: .zero) { [weak editor] in editor?.goTo([type]) }
            } label: {
                DetailShapeRow(symbol: TypesStyle.typeRowSymbol, name: TypesStyle.menuName(name), dimmed: isMissing)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .disabled(isGone)
            Button { editor?.removeTypeLink(link.shape, from: owner) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel(TypesStyle.removeType)
                .disabled(editor?.isReadOnly(inFile: owner) ?? true)
        }
    }
}
