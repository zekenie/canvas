import AppKit
import Canvas
import Find

extension PluginID {
    public static let mentionFind: PluginID = "mention-find"
}

/// Mention text, for Find: on every kind that draws some (`MentionTexts`: a note's text, a schema
/// card's description, an arrow's label), each placement's text as it reads, each mention its
/// target's live name (as its pill shows it), so a name is found where its pill is; a hit in a name
/// marks the whole pill, which is one character of the drawn text. A placement drawn over the canvas
/// itself (`overCanvas`: an arrow's label) is washed, whose color follows the appearance, where one
/// on the shape's surface is marked as a highlighter does; the two are contributions of their own,
/// each asked for its own placements. Its rects come from the render's own layout, kept with the
/// drawn text by text and width (`MentionTextMemo`), so a hit's rects are a glyph range looked up. A rename changes the texts of what mentions the shape renamed: those are what
/// Mentions' rows name (`rowsAffected(by:)`), read before any text, so the names read are the
/// commit's. A plugin value of its own, after Find and Mentions, so a list without Find leaves it
/// out.
public struct MentionFindPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .mentionFind }

    public func register(into registrar: inout PluginRegistrar) {
        let draws: @MainActor (FindableKind) -> Bool = { !$0.registry.contributions(to: MentionTexts.self, for: $0.kind).isEmpty }
        // The commit's renames are asked of one of them: both read the same shapes' texts.
        registrar.findableTexts("mention text", where: draws,
                                affected: { changes, context in context.service(MentionState.self)?.rowsAffected(by: changes) ?? [] },
                                texts: { record, context in MentionFind.texts(of: record, overCanvas: false, in: context.editor) },
                                rects: { record, field, ranges, context in MentionFind.rects(of: ranges, in: field, of: record, in: context.editor) })
        registrar.findableTexts("mention text over the canvas", where: draws, look: .wash,
                                texts: { record, context in MentionFind.texts(of: record, overCanvas: true, in: context.editor) },
                                rects: { record, field, ranges, context in MentionFind.rects(of: ranges, in: field, of: record, in: context.editor) })
    }
}

@MainActor
enum MentionFind {
    /// Each placement's text drawn on the shape's surface (else over the canvas), by its place in
    /// the kind's list ("0", "1", …): its runs, each mention as its pill names it now.
    static func texts(of record: AnyShapeRecord, overCanvas: Bool, in editor: CanvasEditor) -> [FindableText] {
        let state = editor.mentions
        return editor.registry.mentionTextPlacements(of: record, in: editor.shapeContext).enumerated().compactMap { index, placement in
            placement.overCanvas == overCanvas ? FindableText(field: String(index), text: reading(of: placement, state: state).text) : nil
        }
    }

    /// A placement's text as Find reads it: each mention as its pill names it, its target's live
    /// name, else the name the mention holds.
    private static func reading(of placement: MentionTextPlacement, state: MentionState?) -> MentionReading {
        placement.text.reading { id, stored in state?.resolve(id).appearance?.label ?? stored }
    }

    /// Where each range of a placement's text is drawn, from the shape's bounds' top-left: the
    /// range mapped to the drawn text (a name to its pill's character), looked up in the drawn
    /// text's layout in its box.
    static func rects(of ranges: [Range<Int>], in field: String, of record: AnyShapeRecord, in editor: CanvasEditor) -> [[CGRect]] {
        let none = ranges.map { _ in [CGRect]() }
        let placements = editor.registry.mentionTextPlacements(of: record, in: editor.shapeContext)
        guard let index = Int(field), placements.indices.contains(index),
              let bounds = editor.shapeContext.geometry(of: record.id)?.bounds, !bounds.isNull else { return none }
        let placement = placements[index]
        let box = placement.laidOutBox
        let read = reading(of: placement, state: editor.mentions)
        let mapped = ranges.map { read.drawnRange(of: NSRange(location: $0.lowerBound, length: $0.count)) }
        var resolver = MentionResolver(registry: editor.registry, lookup: { [unowned editor] in editor.shape(inFile: $0) })
        let entry = MentionTextMemo.shared.entry(for: placement, resolver: &resolver)
        let found = entry.lineRects(of: mapped.map { $0.length > 0 ? $0 : NSRange(location: NSNotFound, length: 0) }, in: box.size, style: placement.style)
        let dx = box.minX - bounds.minX, dy = box.minY - bounds.minY
        return zip(mapped, found).map { range, rects in
            range.length == 0 ? [] : rects.map { $0.offsetBy(dx: dx, dy: dy) }
        }
    }
}
