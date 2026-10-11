import Canvas

extension PluginID {
    public static let proseMaps: PluginID = "prose-maps"
}

/// Prose maps, as a plugin: every editor's `ProseMapService`, which says which words of a text in
/// plain words say which part of a text in a lower language, for any plugin that keeps the two (a
/// type's words and its schema), and the frame's end it asks from. Generic: it knows no
/// kind and no target; a target is a type of its plugin's (`ProseTarget`), and what's drawn of a map
/// is its reader's. It asks the editor's model, so it does nothing without `LanguageModelsPlugin`.
public struct ProseMapsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .proseMaps }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ProseMapService(editor: $0) }
        registrar.overlay(ProseMapFrames())
    }
}

/// Where a frame ends, an overlay that draws nothing: it hands the pairs the frame read with no answer
/// to the editor's prose maps, which asks about those it may.
struct ProseMapFrames {}

extension ProseMapFrames: CanvasOverlay {
    var space: OverlaySpace { .view }
    func draw(in context: OverlayContext) { context.editor.proseMaps?.frameEnded() }
}

extension CanvasEditor {
    /// What shapes' words say of their targets; nil without ProseMapsPlugin.
    public var proseMaps: ProseMapService? { service(ProseMapService.self) }
}

extension RenderContext {
    /// The editor's prose maps, as a render reads them; nil without ProseMapsPlugin.
    public var proseMaps: ProseMapService? { service(ProseMapService.self) }
}
