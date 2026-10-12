import AppKit
import Canvas
import Mentions
import Types

// A note zoomed out (`CustomSkeleton`): its yellow, and a bar where each line of its text would
// be, counted from its characters rather than laid out.

extension StickyNoteDefinition: CustomSkeleton {
    /// Its laid-out frame in its yellow (a type's, in its white paper, which follows the appearance: resolved
    /// here, in the frame's), square (its 4-point corners are under a point and a half on screen
    /// here) and with no shadow, and its text greeked (`SkeletonTextBars`, each mention as wide as
    /// its pill): two fills, whatever it says; a note with rows adds a third, their bars (`fillTypeRowBars`), and its
    /// words' stop above them. Its outline is its frame's, as the core draws it.
    func renderSkeleton(_ shape: ShapeRecord<StickyNote>, in context: RenderContext) {
        let frame = context.shapes.frame(of: shape)
        let isType = shape[TypeSchemaProperty.self] != nil
        context.cg.setFillColor(isType ? NoteStyle.typePaperCG : NoteStyle.skeletonFill)
        context.cg.fill(frame)
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
    /// The note's 16-point text greeked: 0.52 em a column, its 19-point lines, and each line's bar
    /// where string drawing inks a lowercase x in it, 6.5 to 15 points down, the x-height.
    static let skeletonText = SkeletonTextMetrics(advance: SkeletonTextMetrics.systemFontColumn * 16, lineHeight: lineHeight,
                                                  barTop: 6.5, barHeight: 8.5)
}
