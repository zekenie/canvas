import Canvas
import DetailPanel
import Foundation
import Selection
import SwiftUI

// The panel's Fields, in the Types tab after the Types rows: each field the shape's types give it, a
// control by its kind, and the values no field names, dimmed with a way to remove each. Every write goes
// through the one writer (`FieldWriter`), so a hand change here is a step named for its field, as a row's
// is. What a field with more in it looks like is `FieldForm`'s.

extension TypesStyle {
    public static let fieldsTitle = "Fields"
    /// Between a field's name and the form under it.
    static let formSpacing: CGFloat = 2
    /// A number, a date or an either: one line, as the text view lays it out.
    public static let fieldLine: CGFloat = 22
    /// A value no field names.
    static let unnamedValueSymbol = "circle.dashed"
    /// `Remove Nickname`: the step of taking a value no field names out, and its minus's label.
    public static func removeValue(_ key: String) -> String {
        let words = FieldName.words(of: ChainField(name: key, schema: .null)).split(whereSeparator: \.isWhitespace)
        return (["Remove"] + words.map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined(separator: " ")
    }
}

/// One row of the section.
public enum FieldsPanelRow: Identifiable {
    /// A field a box, a checkbox or a menu suits: the kinds it takes (an either's two), and what it holds.
    case plain(Resolved.Field, [PlainKind], JSONValue?)
    /// Every other kind: a field with more in it, a pointer, pointers, `Other`.
    case form(Resolved.Field, FieldKind)
    /// A value no field names: its key as written.
    case unnamed(String, JSONValue)

    public var id: String {
        switch self {
        case .plain(let field, _, _), .form(let field, _): "f:" + field.field.name
        case .unnamed(let key, _): "u:" + key
        }
    }
}

/// Every decision the section makes, with no view.
@MainActor
public enum FieldsPanelModel {
    /// The fields in row order, each with its control, then the values no field names, in key order.
    public static func rows(of record: AnyShapeRecord, book: FieldBook) -> [FieldsPanelRow] {
        let values = record[FieldValuesProperty.self] ?? FieldValues()
        let resolved = book.fields(of: record)
        var rows: [FieldsPanelRow] = resolved.fields.map { field in
            let value = values[field.field.name]
            switch book.kind(of: field) {
            case .plain(let kind): return .plain(field, [kind], value)
            case .either(.plain(let first), .plain(let second)): return .plain(field, [first, second], value)
            case let kind: return .form(field, kind)
            }
        }
        for key in values.keys(unnamedBy: resolved) {
            if let value = values[key] { rows.append(.unnamed(key, value)) }
        }
        return rows
    }

    /// The problems at the field's own path, in the check's order. Those deeper (in a group, an item) are
    /// said at their own rows, by the form.
    public static func problems(of field: Resolved.Field, in check: FieldCheck) -> [FieldProblem] {
        check.problems(at: FieldPath(field: field.field.name))
    }

    /// How a box shows what is stored: the kinds' own forms, except that a text keeps its line breaks.
    public static func shown(_ value: JSONValue?, as kinds: [PlainKind]) -> String {
        guard let value else { return "" }
        let shown = FieldText.shown(value, asOneOf: kinds)
        if case .string(let text) = value, text.contains(where: \.isNewline), shown == FieldText.shown(.string(text), asOneOf: []) { return text }
        return shown
    }
}

extension FieldBook {
    /// Whether the section is shown: the shape's types give it a field, or it holds a value. A kept lookup.
    func givesFieldsOrValues(_ record: AnyShapeRecord) -> Bool {
        !fields(of: record).fields.isEmpty || record[FieldValuesProperty.self] != nil
    }
}

@MainActor
func registerFieldsPanel(into registrar: inout PluginRegistrar) {
    // A type's own note shows kinds on the note, never values; a note that was a Person and is none now
    // still holds its values, so they can be seen and removed.
    registrar.detailsForEveryShape(where: {
        $0[TypeSchemaProperty.self] == nil && ($0[IsAProperty.self] != nil || $0[FieldValuesProperty.self] != nil)
    }) {
        DetailSection(TypesStyle.fieldsTitle, in: TypesTab.self, id: "fields") { $record in FieldsList(record: $record) }
            .enabledWhileReadOnly()
            .shownWhile { shape, context in context.service(FieldBook.self)?.givesFieldsOrValues(shape) == true }
    }
}

/// The fields of a shape, and the values no field names.
struct FieldsList: View {
    @ShapeBinding var record: AnyShapeRecord

    var body: some View {
        let id = $record.shapeID, writer = $record.service(FieldWriter.self), checks = $record.service(FieldChecks.self)
        // A type's change reaches this view (a field added to Order shows on a selected Order).
        let _ = $record.service(TypeIndex.self)?.observeChanges()
        let isReadOnly = writer?.editor?.isReadOnly(id) ?? true
        let check = checks?.check(of: record) ?? .clean
        let rows = $record.service(FieldBook.self).map { FieldsPanelModel.rows(of: record, book: $0) } ?? []
        if let writer {
            ForEach(rows) { row in
                switch row {
                case .plain(let field, let kinds, let value):
                    FieldRowView(field: field, kinds: kinds, value: value, id: id, writer: writer, checks: checks, isReadOnly: isReadOnly)
                    FieldProblems(problems: FieldsPanelModel.problems(of: field, in: check))
                case .form(let field, let kind):
                    if let editor = writer.editor {
                        VStack(alignment: .leading, spacing: TypesStyle.formSpacing) {
                            Text(FieldName.words(of: field.field)).foregroundStyle(.secondary)
                            FieldForm(FieldFormContext(editor: editor, shape: id, path: FieldPath(field: field.field.name), field: field, kind: kind,
                                                       mode: .values, isReadOnly: isReadOnly, presentation: .panel, step: .ownRun))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    FieldProblems(problems: FieldsPanelModel.problems(of: field, in: check))
                case .unnamed(let key, let value):
                    UnnamedValueRow(key: key, value: value, id: id, writer: writer, isReadOnly: isReadOnly)
                }
            }
        }
    }

}

/// One field's label and control: a text box, a one-line box, a checkbox or a menu.
struct FieldRowView: View {
    let field: Resolved.Field
    let kinds: [PlainKind]
    let value: JSONValue?
    let id: ShapeID
    let writer: FieldWriter
    weak var checks: FieldChecks?
    let isReadOnly: Bool

    var body: some View {
        let path = FieldPath(field: field.field.name), words = FieldName.words(of: field.field)
        LabeledContent(words) {
            Group {
                if kinds == [.yesNo] {
                    DetailCheckbox("", isOn: Binding(get: { value?.boolValue == true }, set: { writer.set(.bool($0), at: path, of: id) }))
                        .accessibilityLabel(words)
                } else if case .choice(let options)? = kinds.first, kinds.count == 1 {
                    FieldChoicePicker(options: options, stored: value, path: path, id: id, writer: writer)
                } else {
                    FieldTextBox(kinds: kinds, stored: value, path: path, id: id, writer: writer, checks: checks,
                                 height: kinds == [.text] ? DetailStyle.textAreaHeight / 2 : TypesStyle.fieldLine)
                }
            }
            .disabled(isReadOnly)
        }
    }
}

/// A box that takes what is typed as it is typed: each keystroke is a write. It holds the text typed
/// while it has the caret, and takes the stored form's text only when the value was changed from
/// outside, on Return, and when the keyboard leaves; nothing typed is refused or changed.
struct FieldTextBox: View {
    let kinds: [PlainKind]
    let stored: JSONValue?
    let path: FieldPath
    let id: ShapeID
    let writer: FieldWriter
    weak var checks: FieldChecks?
    let height: CGFloat
    @State private var draft: String

    init(kinds: [PlainKind], stored: JSONValue?, path: FieldPath, id: ShapeID, writer: FieldWriter, checks: FieldChecks?, height: CGFloat) {
        self.kinds = kinds
        self.stored = stored
        self.path = path
        self.id = id
        self.writer = writer
        self.checks = checks
        self.height = height
        _draft = State(initialValue: FieldsPanelModel.shown(stored, as: kinds))
    }

    var body: some View {
        DetailTextArea(Binding(get: { draft }, set: { typed($0) }), height: height, asTyped: true, onCommit: leave)
            .onChange(of: stored) { if FieldText.value(from: draft, asOneOf: kinds) != stored { draft = FieldsPanelModel.shown(stored, as: kinds) } }
            .onChange(of: kinds) { draft = FieldsPanelModel.shown(stored, as: kinds) }
            .onDisappear(perform: stopTyping)
    }

    /// The first keystroke tells the check this field is being typed in (its problem waits), then writes.
    private func typed(_ new: String) {
        draft = new
        if let checks, checks.typing?.shape != id || checks.typing?.path != path { checks.typing = (id, path) }
        writer.set(FieldText.value(from: new, asOneOf: kinds), at: path, of: id)
    }

    /// Only the box that set it clears it.
    private func stopTyping() {
        if let checks, checks.typing?.shape == id, checks.typing?.path == path { checks.typing = nil }
    }

    /// Done: the box shows the stored form of what was typed (worked out from the draft, which the stored
    /// value may not have caught up to).
    private func leave() {
        stopTyping()
        draft = FieldsPanelModel.shown(FieldText.value(from: draft, asOneOf: kinds), as: kinds)
    }
}

/// A choice: its options by label, a stored value no option holds (so it is seen and can be changed),
/// then None, which clears.
struct FieldChoicePicker: View {
    let options: [FieldOption]
    let stored: JSONValue?
    let path: FieldPath
    let id: ShapeID
    let writer: FieldWriter

    var body: some View {
        let strays = stored.flatMap { value in options.contains { $0.value == value } ? nil : value }
        Picker("", selection: Binding<JSONValue?>(get: { stored }, set: { writer.set($0, at: path, of: id) })) {
            ForEach(options, id: \.value) { Text($0.label).tag(Optional($0.value)) }
            if let strays { Text(FieldText.shown(strays, asOneOf: options.isEmpty ? [] : [.choice(options)])).tag(Optional(strays)) }
            Divider()
            Text(FieldWords.none).tag(Optional<JSONValue>.none)
        }
        .labelsHidden()
    }
}

/// What the check says of a field, once under it, in its tone.
struct FieldProblems: View {
    let problems: [FieldProblem]

    var body: some View {
        ForEach(problems.indices, id: \.self) { place in
            DetailStatusLine(DetailStatus(problems[place].message, tone: problems[place].kind == .wrong ? .error : .warning))
        }
    }
}

/// A value no field names, dimmed, and the minus that takes it out.
struct UnnamedValueRow: View {
    let key: String
    let value: JSONValue
    let id: ShapeID
    let writer: FieldWriter
    let isReadOnly: Bool

    var body: some View {
        HStack(spacing: 2) {
            DetailShapeRow(symbol: TypesStyle.unnamedValueSymbol, name: key, detail: FieldText.shown(value, asOneOf: []), dimmed: true)
            Button { writer.removeUnnamed(key, of: id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel(TypesStyle.removeValue(key))
                .disabled(isReadOnly)
        }
    }
}
