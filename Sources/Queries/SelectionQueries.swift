import Canvas
import Selection

/// `:selected`, in Queries: the shapes the person has selected as the query takes up the file
/// (`editor.selectedShapeIDs`, in the selection's order), which are also what `--ask` tells the
/// model is selected (`QueryState.whereThePersonIs`). It's the person's selection
/// (`registrar.querySelection`), not just a word: a change of the selection while the query runs
/// changes nothing it answers. It reads the editor (`QueryReads.editor`), the selection being the
/// person's.
public struct SelectionQueriesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "selection-queries" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.querySelection(Word.selected.rawValue, "the person has it selected", example: ":selected") { $0.selectedShapeIDs }
    }

    /// The word it adds.
    enum Word: String {
        case selected
    }
}
