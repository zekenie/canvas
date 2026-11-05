import AppKit
import Canvas
import Colors
import Mentions
import Palette
import Types

// A note zoomed out (`CustomSkeleton`): its color's paper, and a bar where each line of its text would
// be, counted from its characters rather than laid out.

extension StickyNoteDefinition: CustomSkeleton {
    /// Its laid-out frame in its color's paper (yellow without one; a type's, in its white paper, which follows the appearance: resolved
    /// here, in the frame's), square (its 4-point corners are under a point and a half on screen
    /// here) and with no shadow, and its text greeked (`SkeletonTextBars`, each mention as wide as
    /// its pill): two fills, whatever it says; a note with rows adds a third, their bars (`fillTypeRowBars`), and its
    /// words' stop above them. A type's adds its edge in the light appearance (`typeSkeletonEdge`), a
    /// hairline just inside its frame: its white is a frame's and a card's there, and with no shadow
    /// nothing else would part them. Its outline is its frame's, as the core draws it.
    func renderSkeleton(_ shape: ShapeRecord<StickyNote>, in context: RenderContext) {
        let frame = context.shapes.frame(of: shape)
        let isType = shape[TypeSchemaProperty.self] != nil
        // A relationship type's pill: the capsule in its type's color, no letters.
        if isType, NoteLayout.pill(shape, in: context.shapes) != nil {
            let color = context.service(TypeIndex.self)?.look(of: shape.id).row.cgColor ?? NoteStyle.pillFallback.cgColor
            context.cg.setFillColor(color)
            context.cg.addPath(NoteStyle.capsule(frame))
            context.cg.fillPath()
            return
        }
        if isType {
            let look = NoteStyle.typeSkeleton
            context.cg.setFillColor(look.paper)
            context.cg.fill(frame)
            if let edge = look.edge {
                // A ring as wide on screen at every zoom; a note too small on screen for one is all edge.
                let width = NoteStyle.typeSkeletonEdgeWidth / context.zoom, inside = frame.insetBy(dx: width, dy: width)
                if !inside.isEmpty { context.cg.addRect(inside) }
                context.cg.addRect(frame)
                context.cg.setFillColor(edge)
                context.cg.fillPath(using: .evenOdd)
            }
        } else {
            context.cg.setFillColor(context.colors(of: shape)?.paper ?? NoteStyle.skeletonFill)
            context.cg.fill(frame)
        }
        var box = frame.insetBy(dx: NoteStyle.padding, dy: NoteStyle.padding)
        // A note with rows: their bars, and the words' bars stop above them. The zoom is asked first, so below
        // `skeletonRowsZoom` a note's skeleton is what it was and no lookup is added.
        if context.showsTypeRowBars, isType || shape[IsAProperty.self] != nil {
            let layout = NoteLayout(shape, in: context.shapes)
            if let block = layout.block {
                box = layout.words
                context.fillTypeRowBars(of: shape, in: block)
            }
        }
        context.fillSkeletonText(SkeletonTextBars(shape.props.text.runs, in: box, metrics: NoteStyle.skeletonText))
    }
}

extension NoteStyle {
    static let skeletonFill = color.cgColor
    /// A type's skeleton's edge, standing for the shadow it has in full: its white paper is a
    /// frame's surface, and about a colored frame's, in the light appearance. Clear in the dark,
    /// where the paper (0.92) stands off every ground and a shadow doesn't show.
    static let typeSkeletonEdge = NSColor(name: nil) { $0.isDark ? .clear : NSColor(white: 0, alpha: 0.16) }
    /// The edge's width, in view points: a hairline at every zoom, as a frame's border is.
    static let typeSkeletonEdgeWidth: CGFloat = 1
    /// The note's 16-point text greeked: 0.52 em a column, its 19-point lines, and each line's bar
    /// where string drawing inks a lowercase x in it, 6.5 to 15 points down, the x-height.
    static let skeletonText = SkeletonTextMetrics(advance: SkeletonTextMetrics.systemFontColumn * 16, lineHeight: lineHeight,
                                                  barTop: 6.5, barHeight: 8.5)
}
