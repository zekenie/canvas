import Boards
import Canvas
import Queries

/// Board names, in QueryLexicon: a query's rows name the boards a shape is inside as the path
/// over the canvas names them (`editor.name(of:root:)`): its owner's title, else the placeholder
/// its kind opens its boards with (`opensBoard(placeholder:)`, "Untitled Subboard", read through
/// `registry.boardPlaceholder(of:)`), else the kind's label. Only the kinds that open their boards
/// have a placeholder; the rest are named by their labels, as Boards names them.
public struct BoardQueriesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "board-queries" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.queryBoardNames { kind, registry in registry.boardPlaceholder(of: kind) }
    }
}
