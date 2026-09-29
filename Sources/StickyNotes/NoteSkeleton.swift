import AppKit
import Canvas
import Mentions

// A note zoomed out (`CustomSkeleton`): its yellow, and a bar where each line of its text would
// be, counted from its characters rather than laid out.

extension StickyNoteDefinition: CustomSkeleton {
    /// Its frame in its yellow, square (its 4-point corners are under a point and a half on screen
    /// here) and with no shadow, and its text greeked (`SkeletonTextBars`, each mention as wide as
    /// its pill): two fills, whatever it says. Its outline is its frame's, as the core draws it.
    func renderSkeleton(_ shape: ShapeRecord<StickyNote>, in context: RenderContext) {
        let frame = shape.frame
        context.cg.setFillColor(NoteStyle.skeletonFill)
        context.cg.fill(frame)
        let box = frame.insetBy(dx: NoteStyle.padding, dy: NoteStyle.padding)
        context.fillSkeletonText(SkeletonTextBars(shape.props.text.runs, in: box, metrics: NoteStyle.skeletonText))
    }
}

extension NoteStyle {
    static let skeletonFill = color.cgColor
    /// The note's 16-point text greeked: 0.52 em a column, its 19-point lines, and each line's bar
    /// where string drawing inks a lowercase x in it, 6.5 to 15 points down, the x-height.
    static let skeletonText = SkeletonTextMetrics(advance: SkeletonTextMetrics.systemFontColumn * 16, lineHeight: lineHeight,
                                                  barTop: 6.5, barHeight: 8.5)
}
