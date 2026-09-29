import Canvas
import Queries
import Selection

/// A bridge between two horizontals: `:selected`, the shapes the person has selected as the query
/// takes up the file (`editor.selectedShapeIDs`, in the selection's order), which are also what
/// `--ask` tells the model is selected (`QueryState.whereThePersonIs`). It's the person's selection
/// (`registrar.querySelection`), not just a word: a change of the selection while the query runs
/// changes nothing it answers. Queries has never heard of Selection, nor Selection of queries.
public struct SelectionQueriesPlugin: CanvasPlugin {
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
