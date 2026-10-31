import Canvas
import Foundation
import Titles

/// A row's first value in the issue walk's list: what a plugin shows at the end of the row of a shape it gives a value to (a
/// note's first field, "Nay"), so a person who has the list in front of them sees the thing the issue is about. Validation
/// declares the point and knows no value: a plugin gives one for the kinds its opt-in reaches
/// (`registrar.forShapes(holding: P.self) { $0.issueRowValue { record, editor in … } }`), so a shape with none shows a row
/// of its name alone, and a feature's kinds are named by what they opted into, never by a list here.
///
/// A value is one line in a one-line slot, whatever a plugin gives (a list field's lines, a long text): `Registry.issueRowValue`
/// folds it, each run of whitespace and every line break to a space, and cuts it at `maxLength` characters with an
/// ellipsis, so every contribution reads the same on screen and to VoiceOver.
///
/// Asked only for the rows the list builds (the unfolded boards'), as each is drawn, so a contribution reads a shape's own
/// record and the services it keeps, cheaply.
public enum IssueRowValues {
    /// The longest a value is, in characters, ellipsis included.
    public static let maxLength = 60

    /// A contribution as the row ends in it: on one line, cut at `maxLength` with an ellipsis; nil when nothing is left.
    public static func line(_ value: String) -> String? {
        guard let folded = TitleProperty.folded(value) else { return nil }
        guard folded.count > maxLength else { return folded }
        return folded.prefix(maxLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension IssueRowValues: ExtensionPoint {
    public typealias Contribution = @MainActor (AnyShapeRecord, CanvasEditor) -> String?
    public static var owner: PluginID { .validation }
    /// A value for other kinds' shapes says which: the kinds that hold a property, have a capability, or every shape.
    public static var scope: PointScope { .scoped }

    /// "IssueRowValues → every shape holding fieldValues".
    public static func summary(of contribution: Contribution, for target: ShapeTarget) -> String {
        "IssueRowValues → \(target)"
    }
}

extension ScopedRegistrar {
    /// A row's first value for the shapes of every kind the scope reaches, or nil for a shape that has none. The first
    /// contribution that answers (plugin order) is the row's, as one line.
    public mutating func issueRowValue(_ value: @escaping @MainActor (AnyShapeRecord, CanvasEditor) -> String?) {
        contribute(value, to: IssueRowValues.self)
    }
}

extension Registry {
    /// The first value plugins give a shape's row in the walk's list: the first contribution for its kind that answers with
    /// something to show, folded to one line and cut (`IssueRowValues.line`).
    @MainActor public func issueRowValue(of record: AnyShapeRecord, in editor: CanvasEditor) -> String? {
        for contribution in contributions(to: IssueRowValues.self, for: record.kind) {
            if let value = contribution(record, editor).flatMap(IssueRowValues.line) { return value }
        }
        return nil
    }
}
