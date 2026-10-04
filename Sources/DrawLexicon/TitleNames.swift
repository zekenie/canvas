import Automation
import Canvas
import Titles

// DrawLexicon: what `canvas draw`'s words mean in this app (a name is a title, an edge is a
// connection, a warning is a validation issue), each a plugin of its own over Automation's draw
// points, so the engine can be tested with words of its own (AutomationTests do). It imports the
// concerns its words are about; none of them knows the command line.

/// Draw's names, in DrawLexicon: `canvas draw` names shapes by their titles, as Titles has
/// them. A shape is called what its row and its pill say (`registry.title(of:)`, folded, nil for
/// none); a kind can be given a title when it opts into the one Titles keeps (`TitleProperty`), and
/// a script's title is written there; a kind's titles are derived when Titles works them out from
/// what the kind keeps (a schema card's, from its schema's `"title"`); and a title a script writes is
/// folded as Titles folds one (`TitleProperty.folded`).
public struct TitleNamesPlugin: CanvasPlugin {
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
