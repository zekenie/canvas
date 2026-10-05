import AppKit
import Canvas
import Find

extension PluginID {
    public static let mentionFind: PluginID = "mention-find"
}

/// Mention text, for Find: on every kind that draws some (`MentionTexts`: a note's text, a schema
/// card's description), each placement's text as it reads, each mention its target's live name
/// (as its pill shows it), so a name is found where its pill is; a hit in a name marks the whole
/// pill, which is one character of the drawn text. Its rects come from the render's own layout,
/// kept with the drawn text by text and width (`MentionTextMemo`), so a hit's rects are a glyph
/// range looked up. A rename changes the texts of what mentions the shape renamed: those are what
/// Mentions' rows name (`rowsAffected(by:)`), read before any text, so the names read are the
/// commit's. A plugin value of its own, after Find and Mentions, so a list without Find leaves it
/// out.
public struct MentionFindPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .mentionFind }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.findableTexts("mention text", where: { !$0.registry.contributions(to: MentionTexts.self, for: $0.kind).isEmpty },
                                affected: { changes, context in context.service(MentionState.self)?.rowsAffected(by: changes) ?? [] },
                                texts: { record, context in MentionFind.texts(of: record, in: context.editor) },
                                rects: { record, field, ranges, context in MentionFind.rects(of: ranges, in: field, of: record, in: context.editor) })
    }
}

@MainActor
enum MentionFind {
    /// Each placement's text, by its place in the kind's list ("0", "1", …): its runs, each
    /// mention as its pill names it now.
    static func texts(of record: AnyShapeRecord, in editor: CanvasEditor) -> [FindableText] {
        let state = editor.mentions
        return editor.registry.mentionTextPlacements(of: record).enumerated().map { index, placement in
            var text = ""
            for run in placement.text.runs {
                switch run {
                case .text(let plain): text += plain
                case .mention(let id, let stored): text += label(of: id, stored: stored, state: state)
                }
            }
            return FindableText(field: String(index), text: text)
        }
    }

    /// What a pill names its target: its live name, else the name the mention holds.
    private static func label(of id: ShapeID, stored: String, state: MentionState?) -> String {
        state?.resolve(id).appearance?.label ?? stored
    }

    /// Where each range of a placement's text is drawn, from the shape's bounds' top-left: the
    /// range mapped to the drawn text (a name to its pill's character), looked up in the drawn
    /// text's layout in its box.
    static func rects(of ranges: [Range<Int>], in field: String, of record: AnyShapeRecord, in editor: CanvasEditor) -> [[CGRect]] {
        let none = ranges.map { _ in [CGRect]() }
        let placements = editor.registry.mentionTextPlacements(of: record)
        guard let index = Int(field), placements.indices.contains(index),
              let bounds = editor.shapeContext.geometry(of: record.id)?.bounds, !bounds.isNull else { return none }
        let placement = placements[index]
        let box = placement.laidOutBox
        let state = editor.mentions
        // Each run's start in the text read and in the text drawn, and its length in the first.
        var runs: [(read: Int, drawn: Int, length: Int, isPill: Bool)] = []
        var read = 0, drawn = 0
        for run in placement.text.runs {
            switch run {
            case .text(let plain):
                let length = plain.utf16.count
                runs.append((read, drawn, length, false))
                read += length
                drawn += length
            case .mention(let id, let stored):
                let length = label(of: id, stored: stored, state: state).utf16.count
                runs.append((read, drawn, length, true))
                read += length
                drawn += 1
            }
        }
        /// Where a unit of the text read is in the text drawn: in a name, its pill.
        func drawnRange(_ range: Range<Int>) -> NSRange? {
            guard let first = runs.last(where: { $0.read <= range.lowerBound }),
                  let last = runs.last(where: { $0.read <= range.upperBound - 1 }) else { return nil }
            let lower = first.isPill ? first.drawn : first.drawn + range.lowerBound - first.read
            let upper = last.isPill ? last.drawn + 1 : last.drawn + range.upperBound - last.read
            return upper > lower ? NSRange(location: lower, length: upper - lower) : nil
        }
        let mapped = ranges.map(drawnRange)
        var resolver = MentionResolver(registry: editor.registry, lookup: { [unowned editor] in editor.shape(inFile: $0) })
        let entry = MentionTextMemo.shared.entry(for: placement, resolver: &resolver)
        let found = entry.lineRects(of: mapped.map { $0 ?? NSRange(location: NSNotFound, length: 0) }, in: box.size, style: placement.style)
        let dx = box.minX - bounds.minX, dy = box.minY - bounds.minY
        return zip(mapped, found).map { range, rects in
            range == nil ? [] : rects.map { $0.offsetBy(dx: dx, dy: dy) }
        }
    }
}
