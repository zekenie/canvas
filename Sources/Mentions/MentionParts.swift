import Canvas
import CoreGraphics
import Selection

/// A selected note's live mentions as parts (Selection's `ShapeParts`, keyboard navigation's principles
/// 1 and 3): "Go to <name>" for each, in text order, a target mentioned twice listed once, at its
/// first pill. ⌥Tab reaches them, Return or Space follows (the double-click's `follow`), and VoiceOver
/// names them. The rect is the pill's, from the same layout the faces and Find read
/// (`mentionPills(of:)`). A shape being edited lists none (Selection's rule): its text view has the
/// pills, and the commands.
@MainActor
func registerMentionParts(into registrar: inout PluginRegistrar) {
    registrar.forShapes(adopting: .mentionText) { drawn in
        drawn.shapeParts(named: "mentions") { editor, shape in
            // A skeleton draws no pill, so none is a part (Adornments' and References' drop out the same way).
            guard let mentions = editor.mentions, !editor.drawsSkeleton(of: shape.id) else { return [] }
            var seen: Set<ShapeID> = []
            return editor.mentionPills(of: shape.id).compactMap { pill in
                guard pill.isLive, seen.insert(pill.target).inserted else { return nil }
                let label = mentions.resolve(pill.target).appearance?.label ?? ""
                let target = pill.target
                return ShapePart(id: target, title: MentionStyle.goToPart(label), role: .link, rect: pill.frame) { _ in
                    mentions.follow(target)
                }
            }
        }
    }
}
