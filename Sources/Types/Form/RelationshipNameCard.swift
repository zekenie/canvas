import Adornments
import AppKit
import Canvas
import CoreGraphics
import Titles

// The card that names a relationship type the drag between two types made. A note placed by the gesture has its
// words for an editor, and a name typed there would be the type's words (and wake the model), so the note is
// selected and not edited, and a one-field card shows at its pill, with the caret in it, shown by the writer
// itself inside its step (`CanvasCard.adoptsPress`): what is typed joins the step the gesture made, so one Undo,
// once the card is dismissed, takes back the note, both arrows and the name.

extension TypesStyle {
    /// How wide the card is, in view points.
    public static let nameCardWidth: CGFloat = 180
    /// Around the field, in view points.
    static let nameCardInset = NSSize(width: 10, height: 8)
    /// The name's size, as a row's value reads.
    static let nameCardFontSize: CGFloat = 13
}

/// The field in the card: a line of text, every substitution off, that hands a change and a key to its card.
@MainActor
final class RelationshipNameCardView: NSView, NSTextViewDelegate {
    let field = FieldCellEditor()
    /// The name as typed, after each change.
    var typed: ((String) -> Void)?
    /// Return, Esc or Tab: the card is done.
    var done: (() -> Void)?
    private var isShowing = false

    init() {
        super.init(frame: .zero)
        let font = NSFont.systemFont(ofSize: TypesStyle.nameCardFontSize)
        field.font = font
        field.textColor = TypesStyle.formValueInk
        field.typingAttributes = [.font: font, .foregroundColor: TypesStyle.formValueInk]
        field.delegate = self
        field.setAccessibilityLabel(TypesStyle.nameRelationshipType)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The room the card wants: its width and a line with the inset above and below it.
    var wanted: CGSize {
        let font = NSFont.systemFont(ofSize: TypesStyle.nameCardFontSize)
        let line = ceil(font.ascender - font.descender + font.leading)
        return CGSize(width: TypesStyle.nameCardWidth, height: line + 2 * TypesStyle.nameCardInset.height)
    }

    override func layout() {
        super.layout()
        field.frame = bounds.insetBy(dx: TypesStyle.nameCardInset.width, dy: TypesStyle.nameCardInset.height)
    }

    func textDidChange(_ notification: Notification) {
        typed?(field.string)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
             #selector(NSResponder.cancelOperation(_:)):
            done?()
            return true
        default:
            return false
        }
    }
}

/// What a card is to the core: the shape it names, and the key of the step it keeps.
private struct NameCardKey: Hashable { let shape: ShapeID }

extension CanvasEditor {
    /// Shows the card that names the relationship type `id`, at its pill, with the caret in its one field, and false
    /// with nothing shown when none can: the board or the shape is read-only, the shape is not on the board shown or has
    /// no pill or is drawn as a skeleton (zoomed out, where no card shows). Each change writes the title as typed (a
    /// blank is none, so the placeholder returns); Return, Esc and Tab close it, keeping what was typed, and a press
    /// elsewhere closes it as it does any card. Shown inside a writer's step it adopts that step (`adoptsPress`): the
    /// card's writes are that step's, "Name Relationship Type" the step they are if it is shown outside any.
    @discardableResult
    public func nameRelationshipType(_ id: ShapeID) -> Bool {
        guard !isBoardReadOnly, !isReadOnly(id), document[id] != nil, let rect = titlePillRect(of: id) ?? adornmentAnchor(of: id) else { return false }
        let key = NameCardKey(shape: id)
        let view = RelationshipNameCardView()
        let wanted = view.wanted
        let card = CanvasCard(id: key, about: id, anchor: rect, view: view, firstResponder: view.field,
                              stepName: TypesStyle.nameRelationshipType, adoptsPress: true,
                              size: { room in CGSize(width: min(wanted.width, room.width), height: wanted.height) })
        view.typed = { [weak self] text in
            guard let self else { return }
            let title = TitleProperty.folded(text) ?? ""
            // A change that changes nothing (the same blank twice) is no step.
            if (self.document[id]?[TitleProperty.self] ?? "") != title {
                self.transact(nil, coalescing: key) { $0.update(id) { $0[TitleProperty.self] = title } }
            }
            // The pill grows with the name, and the card stays under it.
            if let moved = self.titlePillRect(of: id) { self.moveCard(to: moved) }
        }
        view.done = { [weak self] in self?.closeCard() }
        return showCard(card)
    }
}
