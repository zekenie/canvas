import Adornments
import Canvas
import CoreGraphics
import Find

extension PluginID {
    public static let titleFind: PluginID = "title-find"
}

/// Titles, for Find: on every kind that took a title (`.titled`: one someone names, `TitleProperty`, or
/// one it derives), the title as Titles reads it (`registry.title(of:)`). A hit rings the
/// whole pill, which may cut the title short (its frame, Adornments', is in view points, so it's
/// laid out again as the zoom changes); zoomed out, where the title is said on the shape, it's
/// tinted where its cover is (`titleCover(of:)`), or its tab, which shows zoomed out too
/// (`titlePillRect(of:)`). A shape whose pill a look hides (`hidesPill`) gives
/// no title text: there is no pill to ring, and whatever hides it says the name elsewhere. A plugin
/// value of its own, after Find and Titles, so a list without Find leaves it out.
public struct TitleFindPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .titleFind }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.forShapes(adopting: .titled) { titled in
            titled.findableTexts("title", look: .ring, followsZoom: true,
                                 zoomedOut: { record, _, context in
                                     context.editor.titleCover(of: record.id)?.rect ?? context.editor.titlePillRect(of: record.id)
                                 },
                                 texts: { record, context in
                                     // A hidden pill has no frame (no rects below), so its title would count and light nothing:
                                     // whatever hides it says the name elsewhere.
                                     guard let title = context.registry.title(of: record),
                                           context.registry.titlePillLook(of: record, title: title, in: TitleLookContext(context.editor))?.hidesPill != true else { return [] }
                                     return [FindableText(field: TitleProperty.key.rawValue, text: title)]
                                 },
                                 rects: { record, _, ranges, context in
                                     let editor = context.editor
                                     guard let pill = editor.titlePillRect(of: record.id),
                                           let bounds = editor.shapeContext.geometry(of: record.id)?.bounds, !bounds.isNull else {
                                         return ranges.map { _ in [] }
                                     }
                                     let ring = pill.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                                     return ranges.map { _ in [ring] }
                                 })
        }
    }
}
