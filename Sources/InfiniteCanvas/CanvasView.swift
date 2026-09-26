import AppKit

/// The infinite canvas.
///
/// Notes live in world coordinates and `camera` maps them onto the view. Everything is drawn by
/// hand in `draw(_:)` through the camera transform, so content stays crisp at every zoom level.
/// The only subview is a `NoteEditor`, shown over a note while its text is being edited.
final class CanvasView: NSView {
    private var camera = Camera() {
        didSet {
            layoutEditor()
            needsDisplay = true
        }
    }
    private var notes: [StickyNote] = []
    private var selectedID: StickyNote.ID?
    private var editor: NoteEditor?
    private var drag: Drag?

    private enum Drag {
        case panning(last: CGPoint)
        case movingNote(id: StickyNote.ID, grabOffset: CGSize)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        notes = Self.welcomeNotes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        Style.canvasBackground.setFill()
        dirtyRect.fill()
        drawGrid(in: context)

        context.saveGState()
        context.scaleBy(x: camera.zoom, y: camera.zoom)
        context.translateBy(x: -camera.origin.x, y: -camera.origin.y)
        // Pad the visible area so shadows of notes just offscreen still get drawn.
        let visible = camera.toWorld(bounds).insetBy(dx: -40, dy: -40)
        for note in notes where note.frame.intersects(visible) {
            drawNote(note, in: context)
        }
        context.restoreGState()
    }

    private func drawGrid(in context: CGContext) {
        var spacing = Style.gridSpacing
        while spacing * camera.zoom < Style.minGridSpacingOnScreen {
            spacing *= 2
        }

        // Dots are placed in view space so they stay the same size at every zoom level.
        let step = spacing * camera.zoom
        let startX = (floor(camera.origin.x / spacing) * spacing - camera.origin.x) * camera.zoom
        let startY = (floor(camera.origin.y / spacing) * spacing - camera.origin.y) * camera.zoom
        let diameter = Style.gridDotDiameter

        var y = startY
        while y < bounds.maxY + diameter {
            var x = startX
            while x < bounds.maxX + diameter {
                context.addEllipse(in: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
                x += step
            }
            y += step
        }
        context.setFillColor(Style.gridDot.cgColor)
        context.fillPath()
    }

    /// Draws in world coordinates; the caller has already applied the camera transform.
    private func drawNote(_ note: StickyNote, in context: CGContext) {
        let zoom = camera.zoom
        let path = CGPath(
            roundedRect: note.frame,
            cornerWidth: Style.noteCornerRadius,
            cornerHeight: Style.noteCornerRadius,
            transform: nil
        )

        // Shadows ignore the current transform, so scale the blur by hand. The offset is zero
        // because shadow offsets live in device space, whose y direction varies by context.
        context.saveGState()
        context.setShadow(offset: .zero, blur: 6 * zoom, color: Style.noteShadow.cgColor)
        context.addPath(path)
        context.setFillColor(Style.noteColor.cgColor)
        context.fillPath()
        context.restoreGState()

        if note.id == selectedID {
            context.addPath(path)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(2 / zoom)
            context.strokePath()
        }

        // While editing, the editor's text view draws the text instead.
        if note.id != editor?.noteID {
            NSAttributedString(string: note.text, attributes: Style.noteTextAttributes).draw(
                with: note.frame.insetBy(dx: Style.notePadding, dy: Style.notePadding),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let worldPoint = camera.toWorld(viewPoint)
        endEditing()

        if let index = notes.lastIndex(where: { $0.frame.contains(worldPoint) }) {
            // Bring the note to the front.
            let note = notes.remove(at: index)
            notes.append(note)
            selectedID = note.id
            if event.clickCount == 2 {
                beginEditing(note.id)
            } else {
                let grabOffset = CGSize(width: worldPoint.x - note.frame.minX, height: worldPoint.y - note.frame.minY)
                drag = .movingNote(id: note.id, grabOffset: grabOffset)
            }
        } else {
            selectedID = nil
            if event.clickCount == 2 {
                addNote(centeredAt: worldPoint)
            } else {
                drag = .panning(last: viewPoint)
                NSCursor.closedHand.push()
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        switch drag {
        case .panning(let last):
            drag = .panning(last: viewPoint)
            camera.pan(by: CGSize(width: viewPoint.x - last.x, height: viewPoint.y - last.y))
        case .movingNote(let id, let grabOffset):
            guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
            let worldPoint = camera.toWorld(viewPoint)
            notes[index].frame.origin = CGPoint(x: worldPoint.x - grabOffset.width, y: worldPoint.y - grabOffset.height)
            needsDisplay = true
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .panning = drag {
            NSCursor.pop()
        }
        drag = nil
    }

    // MARK: - Trackpad and scroll wheel

    /// Two-finger scroll pans (with the system's momentum); holding Command zooms instead.
    override func scrollWheel(with event: NSEvent) {
        // Mouse wheels report coarse line deltas rather than points.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let dx = event.scrollingDeltaX * scale
        let dy = event.scrollingDeltaY * scale

        if event.modifierFlags.contains(.command) {
            camera.zoom(by: exp(dy * 0.01), around: convert(event.locationInWindow, from: nil))
        } else {
            camera.pan(by: CGSize(width: dx, height: dy))
        }
    }

    override func magnify(with event: NSEvent) {
        camera.zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    // MARK: - Keyboard and menu commands

    override func keyDown(with event: NSEvent) {
        // Routes keys to the standard action methods below (Delete, Return, Escape, ...).
        interpretKeyEvents([event])
    }

    override func deleteBackward(_ sender: Any?) {
        deleteSelectedNote()
    }

    override func deleteForward(_ sender: Any?) {
        deleteSelectedNote()
    }

    override func insertNewline(_ sender: Any?) {
        if let selectedID {
            beginEditing(selectedID)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        selectedID = nil
        needsDisplay = true
    }

    @objc func zoomIn(_ sender: Any?) {
        camera.zoom(by: 1.25, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    @objc func zoomOut(_ sender: Any?) {
        camera.zoom(by: 0.8, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    @objc func zoomToActualSize(_ sender: Any?) {
        camera.setZoom(1, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    // MARK: - Notes

    private func addNote(centeredAt point: CGPoint) {
        let size = Style.noteSize
        let note = StickyNote(frame: CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        ))
        notes.append(note)
        beginEditing(note.id)
    }

    private func deleteSelectedNote() {
        guard let selectedID else { return }
        notes.removeAll { $0.id == selectedID }
        self.selectedID = nil
        needsDisplay = true
    }

    private static func welcomeNotes() -> [StickyNote] {
        let texts = [
            "Double-click empty space to add a note.",
            "Drag a note to move it. Double-click it (or select it and press Return) to edit.",
            "Pinch to zoom and scroll with two fingers to pan. Dragging the background pans too.",
            "Select a note and press Delete to remove it.",
        ]
        return texts.enumerated().map { index, text in
            StickyNote(
                frame: CGRect(origin: CGPoint(x: 80 + CGFloat(index) * 240, y: 80), size: Style.noteSize),
                text: text
            )
        }
    }

    // MARK: - Editing

    private func beginEditing(_ id: StickyNote.ID) {
        endEditing()
        guard let note = notes.first(where: { $0.id == id }) else { return }

        let editor = NoteEditor(note: note)
        editor.textView.delegate = self
        addSubview(editor)
        self.editor = editor
        selectedID = id
        layoutEditor()
        window?.makeFirstResponder(editor.textView)
        needsDisplay = true
    }

    private func endEditing() {
        guard let editor else { return }
        window?.makeFirstResponder(self)
        editor.removeFromSuperview()
        self.editor = nil
        needsDisplay = true
    }

    /// Keeps the editor pinned over its note as the camera moves.
    private func layoutEditor() {
        guard let editor, let note = notes.first(where: { $0.id == editor.noteID }) else { return }
        editor.frame = camera.toView(note.frame)
        editor.bounds = CGRect(origin: .zero, size: note.frame.size)
    }
}

extension CanvasView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let editor, let index = notes.firstIndex(where: { $0.id == editor.noteID }) else { return }
        notes[index].text = editor.textView.string
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            endEditing()
            return true
        }
        return false
    }
}
