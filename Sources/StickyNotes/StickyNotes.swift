import AppKit
import Canvas
import Checklists
import Validation

public struct StickyNote: BoxShapeProps {
    public static let kind: ShapeKind = "sticky-note"
    public var frame: CGRect
    public var text: String
    /// Edited in the detail panel's Checklist tab; the canvas shows it as a chip, not in the note.
    public var checklist: [ChecklistItem]
    public init(frame: CGRect = .zero, text: String = "", checklist: [ChecklistItem] = []) {
        self.frame = frame
        self.text = text
        self.checklist = checklist
    }
    public static let defaultSize = CGSize(width: 200, height: 200)
    /// No text and no checklist.
    var isEmpty: Bool { text.allSatisfy(\.isWhitespace) && checklist.isEmpty }
}

extension PluginID {
    public static let stickyNotes: PluginID = "sticky-notes"
}

public struct StickyNotesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .stickyNotes }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(StickyNoteDefinition()) { note in
            let place = note.editingPlacement(size: NoteStyle.size) { StickyNote() }
            note.tool(label: "Note", systemImage: "note.text", shortcut: "n", placing: place)
            note.createOnDoubleClick(place)
            note.validate { shape, _ in                        // opts into the validation horizontal
                shape.props.isEmpty ? [.warning("This note is empty.")] : []
            }
            note.checklist(\.checklist)                        // opts into the checklists horizontal
        }
    }
}

struct StickyNoteDefinition {}

extension StickyNoteDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<StickyNote>, in context: RenderContext) {
        context.fillWithShadow(NoteStyle.path(shape.frame), NoteStyle.color)
        // While editing, the editing view draws the text instead.
        guard !context.isEditing else { return }
        NSAttributedString(string: shape.props.text, attributes: NoteStyle.textAttributes).draw(
            with: shape.frame.insetBy(dx: NoteStyle.padding, dy: NoteStyle.padding),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    func indicatorPath(of shape: ShapeRecord<StickyNote>, in context: ShapeContext) -> CGPath {
        NoteStyle.path(shape.frame)
    }
}

extension StickyNoteDefinition: Editable {
    func makeEditingView(for shape: ShapeRecord<StickyNote>, context: EditContext<StickyNote>) -> EditingView {
        let editor = NoteEditor(text: shape.props.text, size: shape.frame.size, context: context)
        return EditingView(view: editor, firstResponder: editor.textView)
    }
}

@MainActor
enum NoteStyle {
    static let size = StickyNote.defaultSize
    static let cornerRadius: CGFloat = 4
    static let padding: CGFloat = 16
    static let color = NSColor(srgbRed: 1.0, green: 0.87, blue: 0.45, alpha: 1)
    /// Shared by the renderer and the editor so text doesn't shift when editing starts.
    static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 16),
        .foregroundColor: NSColor(white: 0.12, alpha: 1),
    ]
    static func path(_ frame: CGRect) -> CGPath {
        CGPath(roundedRect: frame, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }
}

/// A text view laid over the note being edited. Its frame is in view points and its bounds in
/// world units, so AppKit scales it by the zoom and the text lays out exactly as the canvas draws it.
final class NoteEditor: NSView, NSTextViewDelegate {
    let textView: NSTextView
    private let context: EditContext<StickyNote>

    init(text: String, size: CGSize, context: EditContext<StickyNote>) {
        self.context = context
        textView = NSTextView(frame: CGRect(origin: .zero, size: size))
        super.init(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.textContainerInset = NSSize(width: NoteStyle.padding, height: NoteStyle.padding)
        textView.textContainer?.lineFragmentPadding = 0
        textView.typingAttributes = NoteStyle.textAttributes
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: NoteStyle.textAttributes))
        textView.insertionPointColor = NoteStyle.textAttributes[.foregroundColor] as? NSColor ?? .black
        textView.delegate = self
        clipsToBounds = true
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func textDidChange(_ notification: Notification) {
        context.update { $0.text = textView.string }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        context.end()
        return true
    }
}
