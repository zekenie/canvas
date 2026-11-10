import Canvas

/// The kit's rows, for Find: a table's columns and an enum's values (`RowFind`), an API's endpoints by method and full path
/// (`APIFind`). A plugin value of its own, after Find and the kit's plugin, so a list without Find leaves it out.
public struct EngineeringFindPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .engineeringFind }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { EnumUsers(editor: $0) }
        RowFind.register(into: &registrar)
        APIFind.register(into: &registrar)
    }
}
