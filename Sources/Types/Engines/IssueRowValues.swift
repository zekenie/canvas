import Canvas
import Find
import Titles
import Validation

extension PluginID {
    public static let issueRowValues: PluginID = "issue-row-values"
}

/// Types' value for the issue walk's list: the row of a shape that holds `fieldValues` ends in its first value, the thing
/// the issue is about (a Vote arrow's row reads "Nay"). A note of a type gives the first text Find would, the first field
/// of its row order that holds a value as its row shows it (`RowBook.findTexts(of:)`); a shape whose kind draws no rows (an
/// arrow of a relationship type, a frame, a subboard) the first of its values in its fields' order, as its card or its panel
/// says them (`findTexts(byFields:)`). A shape with no values gives none, so its row is its
/// name alone. A value that is the shape's title (a type whose `$title` is its first field), or a blank one, is skipped for the next field's, so
/// the row never repeats its name. Read from the record and the types alone, as Find reads them, so a row of a board that is not the one shown
/// reads the same. A plugin value of its own, after Types and Validation, the point's owner, so a list without Validation
/// leaves it out.
public struct IssueRowValuesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .issueRowValues }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.forShapes(holding: FieldValuesProperty.self) { valued in
            valued.issueRowValue { record, editor in
                guard let book = editor.service(RowBook.self) else { return nil }
                let texts = editor.registry.typeRows(of: record.kind) == nil ? book.findTexts(byFields: record) : book.findTexts(of: record)
                // A title taken from a field is a copy of that field's value: the row shows what comes after its name. A text with
                // nothing in it (spaces are a value) is no more the row's than a copy, whether the note has a title or not.
                let name = editor.registry.title(of: record)
                return texts.first { text in TitleProperty.folded(text.text).map { $0 != name } ?? false }?.text
            }
        }
    }
}
