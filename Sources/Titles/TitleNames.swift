import Canvas
import Draw

/// Draw's names, in Titles: `canvas draw` names shapes by their titles, as Titles has them. A shape
/// is called what its row and its pill say (`registry.title(of:)`, folded, nil for none); a kind
/// can be given a title when it opts into the one Titles keeps (`TitleProperty`), and a script's
/// title is written there; a kind's titles are derived when Titles works them out from what the
/// kind keeps (a schema card's, from its schema's `"title"`); and a title a script writes is folded
/// as Titles folds one (`TitleProperty.folded`).
public struct TitleNamesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "title-names" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.drawNames(name: { record, registry in registry.title(of: record) },
                            namingProperty: { kind, registry in
                                registry.properties(for: kind).contains(TitleProperty.key) ? TitleProperty.key.rawValue : nil
                            },
                            isDerived: { kind, registry in registry.titleIsDerived(kind) },
                            fold: { TitleProperty.folded($0) })
    }
}
