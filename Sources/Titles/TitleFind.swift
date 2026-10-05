import Adornments
import Canvas
import CoreGraphics
import Find

extension PluginID {
    public static let titleFind: PluginID = "title-find"
}

/// Titles, for Find: on every kind that holds a title someone names (`TitleProperty`) or derives
/// one (a schema card's), the title as Titles reads it (`registry.title(of:)`). A hit rings the
/// whole pill, which may cut the title short (its frame, Adornments', is in view points, so it's
/// laid out again as the zoom changes); zoomed out, where the title is said on the shape, it's
/// tinted where its cover is (`titleCover(of:)`). A plugin value of its own, after Find and
/// Titles, so a list without Find leaves it out.
public struct TitleFindPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .titleFind }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.findableTexts("title", where: { $0.holds(TitleProperty.self) || $0.registry.titleIsDerived($0.kind) },
                                look: .ring, followsZoom: true,
                                zoomedOut: { record, _, context in context.editor.titleCover(of: record.id)?.rect },
                                texts: { record, context in
                                    context.registry.title(of: record).map { [FindableText(field: TitleProperty.key.rawValue, text: $0)] } ?? []
                                },
                                rects: { record, _, ranges, context in
                                    let editor = context.editor
                                    guard let pill = editor.adornmentFrames(of: record.id).first(where: { $0.adornment == .of(TitlePill.self) })?.rect,
                                          let bounds = editor.shapeContext.geometry(of: record.id)?.bounds, !bounds.isNull else {
                                        return ranges.map { _ in [] }
                                    }
                                    let ring = pill.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                                    return ranges.map { _ in [ring] }
                                })
    }
}
