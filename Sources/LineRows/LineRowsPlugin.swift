import Canvas
import Selection

// Rows written as lines, any kind's: a horizontal a kind opts into with `lineRows(_:)`, whose shapes' rows are written a
// line each (a table's columns, an enum's values). Two parts: Field (the line field and the grammar a role's lines are
// read and printed in) and Session (the stops, keys and commits of a shape being edited, which its kind's editing view
// is). The module knows no table: a kind gives its model (`LineModel`) and its grammars.

extension PluginID {
    public static let lineRows: PluginID = "line-rows"
}

/// The kinds written as lines: one contribution a kind (`lineRows(_:)`). Owner LineRows.
public enum LineRowsKinds {}

extension LineRowsKinds: KeyedExtensionPoint {
    public typealias Contribution = LineRowsContribution
    public static var owner: PluginID { .lineRows }
    public static func uniqueKeys(of _: LineRowsContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of contribution: LineRowsContribution, for target: ShapeTarget) -> String {
        "line rows (\(contribution.noun.plural)) → \(target)"
    }
}

/// One kind's rows as lines: what they're called. Only the sugar makes one.
@MainActor
public struct LineRowsContribution {
    public let noun: LineNoun
}

extension ShapeRegistrar {
    /// This kind's rows are written as lines, as `model` says (`LineModel`): its editing view is
    /// `LineRowsView.make(_:context:model:title:)`, and LineRows' faces reach its shapes (`.lineRows`).
    ///
    ///     table.lineRows(TableLines())
    public mutating func lineRows<Model: LineModel>(_ model: Model) where Model.Props == Definition.Props {
        contribute(LineRowsContribution(noun: model.noun), to: LineRowsKinds.self)
    }
}

extension ShapeCapability {
    /// The kinds whose rows are written as lines (`lineRows(_:)`).
    public static let lineRows = ShapeCapability("written as lines") { kind in
        !kind.registry.contributions(to: LineRowsKinds.self, for: kind.kind).isEmpty
    }
}

extension Registry {
    /// What a kind's rows are called, when they're written as lines; nil for a kind whose aren't.
    public func lineRows(of kind: ShapeKind) -> LineRowsContribution? {
        contributions(to: LineRowsKinds.self, for: kind).first
    }
}

/// Rows written as lines: the sessions' service (the light an offer puts on the board, Tab's hops to the next shape of a
/// kind, the layout inputs taken back as editing ends), the light's outline, and the keys the Keyboard Shortcuts window
/// lists for a row.
public struct LineRowsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .lineRows }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { LineRowsService(editor: $0) }
        registrar.outlines { editor in editor.service(LineRowsService.self)?.outlines() ?? Outlines() }
        registrar.keyHint("↩ in a Row", "Next Row; on an Empty Row, Finish", while: .text)
        registrar.keyHint("⌥↑ ⌥↓ in a Row", "Move the Row", while: .text)
        registrar.keyHint("⌘⌫ then ⌫ in a Row", "Delete the Row", while: .text)
        registrar.keyHint("⇧↩ in a Row", "New Shape Beside It", while: .text)
    }
}
