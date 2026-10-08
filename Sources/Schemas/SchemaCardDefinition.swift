import AppKit
import Canvas
import Mentions
import ProseMaps

/// On the main actor as a whole, so its drawing helpers share the protocol's isolation.
@MainActor
struct SchemaCardDefinition {}

/// A white card, its corners a note's, that says what its schema holds in words: its description
/// (the prompt the model writes the schema from), set as a note's text is, each mention of another
/// card a pill (`drawMentionText`), and typed on the card itself (`Editable`). Its name is its
/// title's pill's, above it, after the kind's `{}` (Titles);
/// its schema is its panel's. A card with no description is blank. Zoomed out, the editor draws its
/// skeleton in its place (SchemaSkeleton.swift). Colors are the same in both appearances, as every
/// shape's body is, and gray: the kind's hue is its row's symbol and its ports' dots.
extension SchemaCardDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<SchemaCard>, in context: RenderContext) {
        let frame = shape.frame
        context.fillWithShadow(SchemaStyle.rounded(frame, SchemaStyle.cornerRadius), SchemaStyle.card)
        // A card too small for its padding has no room for text.
        let box = SchemaStyle.textBox(of: frame)
        guard !shape.props.prompt.stored.isEmpty, !box.isEmpty else { return }
        // Its highlights behind their words, a field's one way and a rule's another, under its editor
        // too, whose text lays out as this does (read, too, so a card drawn in full is asked about
        // once it's in step: `SchemaHighlightsShown`), each mention's pill as it's drawn.
        let maps = context.proseMaps, sync = context.service(SchemaSync.self)
        let placed = SchemaHighlightsShown.placed(for: shape, maps: maps, sync: sync)
        if !placed.isEmpty {
            let registry = context.shapes.registry
            let lines = SchemaHighlightsShown.lines(of: shape, maps: maps, sync: sync) {
                registry.mentionResolution(of: $0, lookup: { context.shape(inFile: $0) })
            }
            for (highlight, lines) in zip(placed, lines) {
                context.cg.setFillColor(SchemaStyle.highlightColor(highlight.role))
                for line in lines { context.cg.fill(SchemaStyle.highlightFill(line)) }
            }
        }
        // While editing, the editing view draws the text instead.
        guard !context.isEditing else { return }
        context.drawMentionText(shape.mentionPlacement)
    }

    func indicatorPath(of shape: ShapeRecord<SchemaCard>, in context: ShapeContext) -> CGPath {
        SchemaStyle.rounded(shape.frame, SchemaStyle.cornerRadius)
    }
}

/// A card made from properties, or given a description that way (the command line's `draw`), is as
/// tall as its description, as `setPrompt` would have made it.
extension SchemaCardDefinition: DerivedProps {
    func derive(_ card: inout SchemaCard) { card.setPrompt(card.prompt) }
}

extension ShapeRecord where Props == SchemaCard {
    /// Where the card draws its description: in its padding, in the card's text. The render draws
    /// exactly this, and Mentions finds its pills through it (`mentionText`).
    @MainActor var mentionPlacement: MentionTextPlacement {
        MentionTextPlacement(props.prompt, in: SchemaStyle.textBox(of: frame), style: SchemaStyle.text)
    }
}

/// Its description is typed on the card (`SchemaDescriptionEditor`), from a placed card at once.
extension SchemaCardDefinition: Editable {
    func makeEditingView(for shape: ShapeRecord<SchemaCard>, context: EditContext<SchemaCard>) -> EditingView {
        let editor = SchemaDescriptionEditor(card: shape, context: context)
        return EditingView(view: editor, firstResponder: editor.textView)
    }
}

/// The card's look, in world units, beside `SchemaCardMetrics` (what its size comes from). Fixed
/// colors: like the sticky note and the subboard, the card is the same in both appearances; only
/// the canvas around it changes.
@MainActor
enum SchemaStyle {
    /// A note's (`NoteStyle.cornerRadius`).
    static let cornerRadius: CGFloat = 4
    /// The skeleton's edge, inside its frame, in view points, and its gray: where the card's shadow
    /// showed as a device pixel or two darker than the light canvas just outside it (228 and 242 on
    /// its 246 at 30%, 239 at 15%), a device pixel on a Retina screen of about that gray, so the
    /// white card still has an edge there. On the dark canvas the shadow didn't show, and the edge
    /// is a white card's softer rim.
    static let skeletonEdgeWidth: CGFloat = 0.5
    static let skeletonEdge = NSColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1)

    static let card = NSColor.white
    /// The description's color, a note's text's (`NoteStyle.text`), made the same way.
    static let textColor = NSColor(white: 0.12, alpha: 1)
    /// Behind the words a highlight links to the schema: a field's pale blue, a rule's pale amber,
    /// light enough on the white card that the text stays the text's gray.
    static let fieldHighlight = NSColor(srgbRed: 0.20, green: 0.47, blue: 0.96, alpha: 0.16).cgColor
    static let validationHighlight = NSColor(srgbRed: 0.96, green: 0.62, blue: 0.04, alpha: 0.24).cgColor
    static func highlightColor(_ role: LinkRole) -> CGColor {
        switch role {
        case .element: fieldHighlight
        case .rule: validationHighlight
        }
    }
    /// What a highlight fills of a line its words are on (`SchemaHighlightsShown.lines`): its words'
    /// width, and the line's height less half a point above and below, so highlights on lines one
    /// under the other stay apart.
    static func highlightFill(_ line: CGRect) -> CGRect { line.insetBy(dx: 0, dy: 0.5) }
    /// The row's symbol in the table of contents, and its ports' dots (`SchemaLink.color`): magenta
    /// (hue 314°), clear of the subboard's indigo (241°), of red, orange and green (what validation
    /// and snapping say), of the note's yellow and its links' amber, and the system accent, so color
    /// tells a schema from a board. 5.1:1 on white, as the indigo was.
    static let accent = NSColor(srgbRed: 0.75, green: 0.18, blue: 0.62, alpha: 1)

    /// The description's style, shared by the render and the editor, so its text and its pills don't
    /// move as editing starts: a note's text (`NoteStyle.text`), the system font at 16 points, every
    /// line 19 points tall (`SchemaCardMetrics.lineHeight`), string drawing's own pitch for the font,
    /// which TextKit 2 would set a point closer; its pills in its color, on the card's surface.
    static let text = MentionTextStyle(font: .systemFont(ofSize: 16), color: textColor, lineHeight: SchemaCardMetrics.lineHeight)
    /// Its attributes: its font, its color and its fixed lines.
    static var textAttributes: [NSAttributedString.Key: Any] { text.attributes }
    /// Where the editor's text starts in the card. At the same line height, TextKit 2 sets a line's
    /// glyphs a point lower in it than string drawing does, so the editor's text starts a point
    /// higher than the render's and its lines fall exactly on the render's (as a note's editor's).
    static let editorInset = NSSize(width: SchemaCardMetrics.padding, height: SchemaCardMetrics.padding - 1)
    /// The description greeked zoomed out, as a note's text is: 0.52 em a column of its 16 points,
    /// its 19-point lines, and each line's bar over its x-height, 6.5 to 15 points down.
    static let skeletonText = SkeletonTextMetrics(advance: SkeletonTextMetrics.systemFontColumn * 16, lineHeight: SchemaCardMetrics.lineHeight,
                                                  barTop: 6.5, barHeight: 8.5)
    /// The card's colors zoomed out, made once.
    static let skeletonCard = card.cgColor, skeletonEdgeColor = skeletonEdge.cgColor

    /// Where the description is in a card's frame: inside its padding.
    static func textBox(of frame: CGRect) -> CGRect {
        frame.insetBy(dx: SchemaCardMetrics.padding, dy: SchemaCardMetrics.padding)
    }

    /// How tall a card `width` wide is to show all of `text` as it's drawn: its lines (the empty one
    /// after a last Return too, where the caret is), and the padding above and below, with half a
    /// point spare so string drawing never cuts the last line; never shorter than one line
    /// (`SchemaCardMetrics.emptyHeight`). `height`, the card's own, is kept when the width leaves no
    /// room for text to measure. A note's measure (`NoteStyle.fittedHeight`), with a line for its
    /// least. Each mention is measured as a live pill by the name it holds (`measuredString`), as a
    /// pure function of the text: as wide as it's drawn while its card is called that.
    static func fittedHeight(of text: SchemaPromptText, width: CGFloat, keeping height: CGFloat) -> CGFloat {
        let inner = width - SchemaCardMetrics.padding * 2
        guard inner > 0 else { return height }
        return fittedHeight(of: self.text.measuredString(text, width: inner), width: width, keeping: height)
    }

    /// The same, of the text as it's shown (the editor's, each pill as its card is called now).
    static func fittedHeight(of shown: NSAttributedString, width: CGFloat, keeping height: CGFloat) -> CGFloat {
        let padding = SchemaCardMetrics.padding, inner = width - padding * 2
        guard inner > 0 else { return height }
        let lines = shown.boundingRect(with: CGSize(width: inner, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
        return max(SchemaCardMetrics.emptyHeight, (lines + 0.5).rounded(.up) + padding * 2)
    }

    /// A rounded rect, its radius at most half its shorter side.
    static func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let radius = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
