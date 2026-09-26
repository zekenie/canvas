import AppKit

enum CanvasTool {
    case select, arrow, ellipse
}

/// The infinite canvas.
///
/// Shapes and arrows live in world coordinates and `camera` maps them onto the view. Everything is
/// drawn by hand in `draw(_:)` through the camera transform, so content stays crisp at every zoom
/// level. The only subview is a `NoteEditor`, shown over a note while its text is being edited.
///
/// Arrow behavior (drawing, binding to shapes, bending, and the overlays that go with it) lives
/// in CanvasView+Arrows.swift and closely follows tldraw's. Arrows reach shapes only through
/// `connectables`.
final class CanvasView: NSView {
    var tool = CanvasTool.select {
        didSet {
            guard tool != oldValue else { return }
            resetArrowToolTargeting()
            hovered = nil
            hoveredHandle = nil
            updateCursor()
        }
    }
    /// Called when the canvas switches tools itself, e.g. from a keyboard shortcut.
    var onToolChange: ((CanvasTool) -> Void)?

    enum Selection: Equatable {
        case shape(ShapeID)
        case arrow(Arrow.ID)
    }

    /// A drawable item, by index into `shapes` or `arrows`.
    enum Item: Equatable {
        case shape(Int)
        case arrow(Int)
    }

    enum Interaction {
        case panning(last: CGPoint)
        case movingShape(id: ShapeID, grabOffset: CGSize)
        /// Pressed on an arrow's body; moves it once the pointer passes the drag threshold.
        case pointingArrow(id: Arrow.ID, origin: CGPoint)
        case translatingArrow(ArrowTranslation)
        /// Pressed with the arrow tool; draws an arrow once the pointer passes the drag threshold.
        case pointingWithArrowTool(origin: CGPoint)
        /// Pressed on a selected arrow's handle; drags it once the pointer passes the drag threshold.
        case pointingHandle(arrowID: Arrow.ID, handle: ArrowHandle, origin: CGPoint)
        case draggingHandle(HandleDrag)
    }

    var camera = Camera() {
        didSet {
            layoutEditor()
            needsDisplay = true
        }
    }
    /// Back to front.
    var shapes: [any CanvasShape] = []
    var arrows: [Arrow] = []
    var selection: Selection? { didSet { needsDisplay = true } }
    /// What's under the pointer in the select tool, outlined as a hover hint.
    var hovered: Selection? { didSet { if hovered != oldValue { needsDisplay = true } } }
    var hoveredHandle: ArrowHandle? {
        didSet {
            guard hoveredHandle != oldValue else { return }
            needsDisplay = true
            updateCursor()
        }
    }
    /// The shape an arrow end would bind to, outlined while aiming or dragging an arrow.
    var targetShapeID: ShapeID? { didSet { if targetShapeID != oldValue { needsDisplay = true } } }
    var interaction: Interaction? { didSet { needsDisplay = true } }

    /// Set by dwelling with the arrow tool (hovering one shape, or holding still after pressing).
    /// Makes a new arrow's start bind precisely where it was pressed.
    var arrowToolIsPrecise = false
    var preciseTimer: Task<Void, Never>?

    /// Smoothed pointer speed in view points per millisecond.
    private(set) var pointerSpeed: CGFloat = 0
    /// The pointer's last known position in view coordinates.
    private(set) var pointerLocation: CGPoint = .zero
    private var lastPointerTime: TimeInterval?
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var recentlyReleasedModifiers: NSEvent.ModifierFlags = []
    private var modifierReleaseTask: Task<Void, Never>?
    private var editor: NoteEditor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        (shapes, arrows) = Self.welcomeBoard()
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
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

    func switchTool(to newTool: CanvasTool) {
        tool = newTool
        onToolChange?(newTool)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        Style.canvasBackground.setFill()
        dirtyRect.fill()
        drawGrid(in: context)

        let connectables = connectablesByID()
        context.saveGState()
        context.scaleBy(x: camera.zoom, y: camera.zoom)
        context.translateBy(x: -camera.origin.x, y: -camera.origin.y)
        // Pad the visible area so shadows of shapes just offscreen still get drawn.
        let visible = camera.toWorld(bounds).insetBy(dx: -40, dy: -40)
        for item in paintOrder() {
            switch item {
            case .shape(let index):
                if shapes[index].frame.intersects(visible) {
                    drawShape(shapes[index], in: context)
                }
            case .arrow(let index):
                drawArrow(geometry(of: arrows[index], connectables: connectables), in: context)
            }
        }
        drawIndicators(in: context, connectables: connectables)
        drawBindingHints(in: context, connectables: connectables)
        context.restoreGState()

        drawArrowHandles(in: context, connectables: connectables)
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
    private func drawShape(_ shape: any CanvasShape, in context: CGContext) {
        switch shape {
        case let note as StickyNote:
            fillWithShadow(notePath(note), Style.noteColor, in: context)
            drawNoteText(note)
        case let ellipse as Ellipse:
            fillWithShadow(CGPath(ellipseIn: ellipse.frame, transform: nil), Style.ellipseColor, in: context)
        default:
            break
        }
    }

    private func fillWithShadow(_ path: CGPath, _ color: NSColor, in context: CGContext) {
        // Shadows ignore the current transform, so scale the blur by hand. The offset is zero
        // because shadow offsets live in device space, whose y direction varies by context.
        context.saveGState()
        context.setShadow(offset: .zero, blur: 6 * camera.zoom, color: Style.shapeShadow.cgColor)
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private func drawNoteText(_ note: StickyNote) {
        // While editing, the editor's text view draws the text instead.
        if note.id != editor?.noteID {
            NSAttributedString(string: note.text, attributes: Style.noteTextAttributes).draw(
                with: note.frame.insetBy(dx: Style.notePadding, dy: Style.notePadding),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
        }
    }

    private func notePath(_ note: StickyNote) -> CGPath {
        CGPath(roundedRect: note.frame, cornerWidth: Style.noteCornerRadius, cornerHeight: Style.noteCornerRadius, transform: nil)
    }

    /// Hover, selection, and binding-target outlines, in world coordinates at constant screen widths.
    private func drawIndicators(in context: CGContext, connectables: [ShapeID: any Connectable]) {
        var outlined: [Selection] = []
        if tool == .select, interaction == nil, let hovered, hovered != selection {
            outlined.append(hovered)
        }
        // Like tldraw, the selection outline steps aside while the selection is being dragged.
        if let selection, !isDraggingSelection {
            outlined.append(selection)
        }
        guard !outlined.isEmpty || targetShapeID != nil else { return }

        context.saveGState()
        for item in outlined {
            switch item {
            case .shape(let id):
                if let path = indicatorPath(ofShape: id) {
                    context.addPath(path)
                }
            case .arrow(let id):
                guard let arrow = arrows.first(where: { $0.id == id }) else { continue }
                let geometry = geometry(of: arrow, connectables: connectables)
                context.addPath(geometry.bodyPath)
                context.addPath(geometry.arrowheadsPath(strokeWidth: Style.arrowStrokeWidth))
            }
        }
        if let targetShapeID, let path = indicatorPath(ofShape: targetShapeID) {
            context.addPath(path)
        }
        context.setStrokeColor(Style.accent.cgColor)
        context.setLineWidth(Style.indicatorWidth / camera.zoom)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    /// The outline drawn around a shape when it's hovered, selected, or targeted by an arrow.
    private func indicatorPath(ofShape id: ShapeID) -> CGPath? {
        switch shapes.first(where: { $0.id == id }) {
        case let note as StickyNote: notePath(note)
        case let ellipse as Ellipse: CGPath(ellipseIn: ellipse.frame, transform: nil)
        default: nil
        }
    }

    private var isDraggingSelection: Bool {
        switch interaction {
        case .movingShape, .translatingArrow, .draggingHandle: true
        default: false
        }
    }

    // MARK: - Items

    /// The shapes arrows can bind to, back to front. Arrow code sees the canvas's shapes only
    /// through this, so a new kind of shape becomes connectable by adopting `Connectable` and
    /// being listed here.
    var connectables: [any Connectable] { shapes.compactMap { $0 as? any Connectable } }

    func connectablesByID() -> [ShapeID: any Connectable] {
        Dictionary(uniqueKeysWithValues: connectables.map { ($0.id, $0) })
    }

    /// Back to front. Each arrow sits just above the highest shape it's bound to, so it's never
    /// hidden behind its own shapes; unbound arrows sit on top.
    func paintOrder() -> [Item] {
        let shapeIndices = Dictionary(uniqueKeysWithValues: shapes.enumerated().map { ($1.id, $0) })
        var arrowsAboveShape: [Int: [Int]] = [:]
        var topArrows: [Int] = []
        for (index, arrow) in arrows.enumerated() {
            let boundShapes = [arrow.start, arrow.end].compactMap { $0.binding.flatMap { shapeIndices[$0.shapeID] } }
            if let highest = boundShapes.max() {
                arrowsAboveShape[highest, default: []].append(index)
            } else {
                topArrows.append(index)
            }
        }
        var order: [Item] = []
        for index in shapes.indices {
            order.append(.shape(index))
            order += (arrowsAboveShape[index] ?? []).map(Item.arrow)
        }
        return order + topArrows.map(Item.arrow)
    }

    /// The front-most item under a world point.
    func item(at worldPoint: CGPoint) -> Item? {
        let connectables = connectablesByID()
        let arrowMargin = Style.arrowHitMargin / camera.zoom + Style.arrowStrokeWidth / 2
        return paintOrder().reversed().first { item in
            switch item {
            case .shape(let index): shapes[index].contains(worldPoint)
            case .arrow(let index): geometry(of: arrows[index], connectables: connectables).distance(to: worldPoint) <= arrowMargin
            }
        }
    }

    func selection(for item: Item) -> Selection {
        switch item {
        case .shape(let index): .shape(shapes[index].id)
        case .arrow(let index): .arrow(arrows[index].id)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        samplePointer(event)
        let viewPoint = pointerLocation
        let worldPoint = camera.toWorld(viewPoint)
        endEditing()

        switch tool {
        case .select:
            break
        case .arrow:
            pressWithArrowTool(at: viewPoint, modifiers: effectiveModifiers(event.modifierFlags))
            return
        case .ellipse:
            addEllipse(centeredAt: worldPoint)
            return
        }

        if case .arrow(let id)? = selection, let handle = arrowHandle(of: id, at: viewPoint) {
            pressHandle(handle, of: id, at: viewPoint, clickCount: event.clickCount)
            return
        }

        switch item(at: worldPoint) {
        case .arrow(let index)?:
            let id = arrows[index].id
            selection = .arrow(id)
            interaction = .pointingArrow(id: id, origin: viewPoint)
        case .shape(let index)?:
            // Bring the shape to the front.
            let shape = shapes.remove(at: index)
            shapes.append(shape)
            selection = .shape(shape.id)
            if event.clickCount == 2, shape is StickyNote {
                beginEditing(shape.id)
            } else {
                let grabOffset = CGSize(width: worldPoint.x - shape.frame.minX, height: worldPoint.y - shape.frame.minY)
                interaction = .movingShape(id: shape.id, grabOffset: grabOffset)
            }
        case nil:
            selection = nil
            if event.clickCount == 2 {
                addNote(centeredAt: worldPoint)
            } else {
                interaction = .panning(last: viewPoint)
            }
        }
        hovered = nil
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        samplePointer(event)
        let viewPoint = pointerLocation
        let worldPoint = camera.toWorld(viewPoint)
        let modifiers = effectiveModifiers(event.modifierFlags)

        switch interaction {
        case .panning(let last):
            interaction = .panning(last: viewPoint)
            camera.pan(by: CGSize(width: viewPoint.x - last.x, height: viewPoint.y - last.y))
        case .movingShape(let id, let grabOffset):
            guard let index = shapes.firstIndex(where: { $0.id == id }) else { return }
            shapes[index].frame.origin = CGPoint(x: worldPoint.x - grabOffset.width, y: worldPoint.y - grabOffset.height)
            needsDisplay = true
        case .pointingArrow(let id, let origin):
            if viewPoint.distance(to: origin) > Style.dragThreshold {
                beginTranslatingArrow(id, from: camera.toWorld(origin))
                updateArrowTranslation(to: worldPoint)
            }
        case .translatingArrow:
            updateArrowTranslation(to: worldPoint)
        case .pointingWithArrowTool(let origin):
            if viewPoint.distance(to: origin) > Style.dragThreshold {
                createArrow(from: camera.toWorld(origin), to: worldPoint, modifiers: modifiers)
            }
        case .pointingHandle(let id, let handle, let origin):
            if viewPoint.distance(to: origin) > Style.dragThreshold {
                beginDraggingHandle(handle, of: id, from: camera.toWorld(origin))
                updateHandleDrag(to: worldPoint, modifiers: modifiers)
            }
        case .draggingHandle:
            updateHandleDrag(to: worldPoint, modifiers: modifiers)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        samplePointer(event)
        switch interaction {
        case .draggingHandle(let drag):
            finishHandleDrag(drag)
        case .pointingWithArrowTool:
            // A click without a drag makes no arrow.
            restartArrowToolTargeting()
        default:
            break
        }
        interaction = nil
        if tool == .select {
            targetShapeID = nil
        }
        updateHover(modifiers: effectiveModifiers(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        samplePointer(event)
        updateHover(modifiers: effectiveModifiers(event.modifierFlags))
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        hoveredHandle = nil
        if interaction == nil {
            resetArrowToolTargeting()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    private func updateHover(modifiers: NSEvent.ModifierFlags) {
        guard interaction == nil else { return }
        switch tool {
        case .select:
            if case .arrow(let id)? = selection, let handle = arrowHandle(of: id, at: pointerLocation) {
                hoveredHandle = handle
                hovered = nil
            } else {
                hoveredHandle = nil
                hovered = item(at: camera.toWorld(pointerLocation)).map(selection(for:))
            }
        case .arrow:
            updateArrowToolTarget(at: camera.toWorld(pointerLocation), modifiers: modifiers)
        case .ellipse:
            break
        }
        updateCursor()
    }

    func updateCursor() {
        let cursor: NSCursor = switch interaction {
        case .panning, .pointingHandle, .draggingHandle: .closedHand
        default: tool != .select ? .crosshair : hoveredHandle != nil ? .openHand : .arrow
        }
        cursor.set()
    }

    private func samplePointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer {
            pointerLocation = point
            lastPointerTime = event.timestamp
        }
        guard let lastPointerTime else { return }
        let elapsedMilliseconds = max((event.timestamp - lastPointerTime) * 1000, 1)
        let speed = point.distance(to: pointerLocation) / elapsedMilliseconds
        // Smoothed like tldraw's: the old value's weight halves every 16 ms.
        pointerSpeed += (speed - pointerSpeed) * (1 - pow(0.5, elapsedMilliseconds / 16))
        if pointerSpeed < 0.01 {
            pointerSpeed = 0
        }
    }

    // MARK: - Modifier keys

    /// Modifiers from an event, plus any released within `Style.modifierReleaseDelay`.
    func effectiveModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask).union(recentlyReleasedModifiers)
    }

    override func flagsChanged(with event: NSEvent) {
        let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let released = heldModifiers.subtracting(held)
        heldModifiers = held
        if !released.isEmpty {
            recentlyReleasedModifiers.formUnion(released)
            modifierReleaseTask?.cancel()
            modifierReleaseTask = Task { [weak self] in
                try? await Task.sleep(for: Style.modifierReleaseDelay)
                guard !Task.isCancelled, let self else { return }
                self.recentlyReleasedModifiers = []
                self.modifiersDidChange(self.heldModifiers)
            }
        }
        modifiersDidChange(effectiveModifiers(held))
    }

    /// Modifiers change how arrow ends bind, so re-evaluate without waiting for the pointer to move.
    private func modifiersDidChange(_ modifiers: NSEvent.ModifierFlags) {
        switch interaction {
        case .draggingHandle:
            updateHandleDrag(to: camera.toWorld(pointerLocation), modifiers: modifiers)
        case nil where tool == .arrow:
            updateArrowToolTarget(at: camera.toWorld(pointerLocation), modifiers: modifiers)
        default:
            break
        }
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

    override func insertText(_ insertString: Any) {
        switch (insertString as? String)?.lowercased() {
        case "a": switchTool(to: .arrow)
        case "o": switchTool(to: .ellipse)
        case "v": switchTool(to: .select)
        default: super.insertText(insertString)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        deleteSelection()
    }

    override func deleteForward(_ sender: Any?) {
        deleteSelection()
    }

    override func insertNewline(_ sender: Any?) {
        if case .shape(let id)? = selection {
            beginEditing(id)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if case .draggingHandle(let drag) = interaction, drag.isCreating {
            cancelArrowCreation(drag)
        } else if interaction != nil {
            return
        } else if tool != .select {
            switchTool(to: .select)
        } else {
            selection = nil
        }
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

    // MARK: - Shapes

    private func addNote(centeredAt point: CGPoint) {
        let note = StickyNote(frame: CGRect(center: point, size: Style.noteSize))
        shapes.append(note)
        selection = .shape(note.id)
        beginEditing(note.id)
    }

    /// Places an ellipse under the pointer and keeps hold of it, so dragging moves it into place.
    private func addEllipse(centeredAt point: CGPoint) {
        let ellipse = Ellipse(frame: CGRect(center: point, size: Style.ellipseSize))
        shapes.append(ellipse)
        selection = .shape(ellipse.id)
        switchTool(to: .select)
        interaction = .movingShape(
            id: ellipse.id,
            grabOffset: CGSize(width: point.x - ellipse.frame.minX, height: point.y - ellipse.frame.minY)
        )
    }

    private func deleteSelection() {
        switch selection {
        case .shape(let id):
            releaseArrows(from: id)
            shapes.removeAll { $0.id == id }
        case .arrow(let id):
            arrows.removeAll { $0.id == id }
        case nil:
            return
        }
        selection = nil
        hovered = nil
        hoveredHandle = nil
    }

    private static func welcomeBoard() -> ([any CanvasShape], [Arrow]) {
        func note(_ x: CGFloat, _ y: CGFloat, _ text: String) -> StickyNote {
            StickyNote(frame: CGRect(origin: CGPoint(x: x, y: y), size: Style.noteSize), text: text)
        }
        let notes = [
            note(80, 80, "Double-click empty space to add a note. Drag a note to move it."),
            note(460, 80, "Double-click a note (or select it and press Return) to edit it."),
            note(840, 80, "Pinch to zoom, scroll with two fingers to pan. Dragging the background pans too."),
            note(80, 420, "Press A for the arrow tool, then drag from one shape to another. Press O to place an ellipse."),
            note(460, 420, "Pause inside a note while drawing to aim at that spot. Hold ⌥ to go all the way in, ⌘ to not attach."),
            note(840, 420, "Select an arrow and drag its middle handle to bend it."),
        ]
        func bound(_ note: StickyNote) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: note.id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        let arrows = [
            Arrow(start: bound(notes[0]), end: bound(notes[1])),
            Arrow(start: bound(notes[3]), end: bound(notes[4])),
            Arrow(start: bound(notes[4]), end: bound(notes[5]), bend: 70),
        ]
        return (notes, arrows)
    }

    // MARK: - Editing

    /// Only notes have text to edit.
    private func beginEditing(_ id: ShapeID) {
        endEditing()
        guard let note = shapes.first(where: { $0.id == id }) as? StickyNote else { return }

        let editor = NoteEditor(note: note)
        editor.textView.delegate = self
        addSubview(editor)
        self.editor = editor
        selection = .shape(id)
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
        guard let editor, let note = shapes.first(where: { $0.id == editor.noteID }) else { return }
        editor.frame = camera.toView(note.frame)
        editor.bounds = CGRect(origin: .zero, size: note.frame.size)
    }
}

extension CanvasView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let editor,
              let index = shapes.firstIndex(where: { $0.id == editor.noteID }),
              var note = shapes[index] as? StickyNote else { return }
        note.text = editor.textView.string
        shapes[index] = note
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            endEditing()
            return true
        }
        return false
    }
}
