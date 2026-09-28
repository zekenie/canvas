import Canvas

/// The panel's own contribution: its state. Every section in it is some plugin's.
public struct DetailPanelPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .detailPanel }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { DetailPanelState(editor: $0) }
    }
}
