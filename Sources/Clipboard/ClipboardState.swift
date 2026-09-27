import AppKit
import Canvas
import Geometry
import Selection

/// Per editor: the copyability rules, gathered once (the registry is frozen), and what copying,
/// cutting and pasting do. Plugins reach them through `CanvasEditor`'s members below.
///
/// What goes on the pasteboard is a small board (`BoardCodec`): the copied shapes back to front,
/// each kind at its version, so a paste into a newer app migrates them as opening a board would.
/// A copied shape names only shapes copied with it: copying lets go of the rest
/// (`ShapeReferencing`), as tldraw's copy does.
@MainActor
final class ClipboardState {
    /// This app's shapes on a pasteboard.
    static let shapesType = NSPasteboard.PasteboardType("com.example.InfiniteCanvas.shapes")

    private unowned let editor: CanvasEditor
    private let pasteboard: NSPasteboard
    /// Each kind's rule (`ShapeCopyability`), found once.
    private let rules: [ShapeKind: @MainActor (AnyShapeRecord) -> Bool]
    private let codec: BoardCodec

    init(editor: CanvasEditor, pasteboard: NSPasteboard) {
        self.editor = editor
        self.pasteboard = pasteboard
        let registry = editor.registry
        rules = registry.kinds.reduce(into: [:]) { rules, kind in
            rules[kind] = registry.contributions(to: ShapeCopyability.self, for: kind).first
        }
        codec = BoardCodec(registry: registry)
    }

    /// Never a shape the board keeps aside; otherwise the kind's own rule, else one for every kind,
    /// else copyable.
    func isCopyable(_ record: AnyShapeRecord) -> Bool { !record.isOpaque && (rules[record.kind]?(record) ?? true) }

    /// The shapes of `ids` that can be copied, back to front, each once.
    private func copyable(_ ids: [ShapeID]) -> [AnyShapeRecord] {
        let document = editor.document
        return Set(ids).compactMap { document.index(of: $0) }.sorted().map { document.shapes[$0] }.filter(isCopyable)
    }

    func canCopy(_ ids: [ShapeID]) -> Bool {
        ids.contains { id in editor.document[id].map(isCopyable) ?? false }
    }

    /// Puts copies of the copyable shapes of `ids` on the pasteboard, in place of what was there.
    /// Returns the shapes copied, back to front; with none, the pasteboard is left as it was.
    @discardableResult
    func copy(_ ids: [ShapeID]) -> [ShapeID] {
        let records = copyable(ids)
        guard !records.isEmpty else { return [] }
        let copied = Set(records.map(\.id)), context = editor.shapeContext
        let content = records.map { $0.remappingReferences({ copied.contains($0) ? $0 : nil }, in: context) }
        let data: Data
        do {
            data = try codec.encode(CanvasDocument(shapes: content))
        } catch {
            assertionFailure("copied shapes don't encode: \(error)")
            return []
        }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.shapesType)
        return records.map(\.id)
    }

    /// Copies, then deletes what it copied, in one transaction: what can't be copied stays.
    func cut(_ ids: [ShapeID]) {
        let copied = copy(ids)
        guard !copied.isEmpty else { return }
        editor.transact { $0.delete(Set(copied)) }
        editor.hovered = nil
    }

    /// Whether the pasteboard holds shapes to paste.
    var hasShapes: Bool { pasteboard.availableType(from: [Self.shapesType]) != nil }

    /// Copies of the shapes on the pasteboard, on top of the board with new ids, then selected
    /// (tldraw's paste). They land where their originals were if any of them would be in view
    /// there, and otherwise centered in the view. Each one's `CopiedFrom` names its original. What
    /// this app can't read (a kind it doesn't install, a newer version of one) is left out.
    func paste() {
        guard let data = pasteboard.data(forType: Self.shapesType), let board = try? codec.decode(data) else { return }
        let records = board.document.shapes.filter { !$0.isOpaque }
        guard !records.isEmpty else { return }
        editor.endEditing()
        let copies = Dictionary(uniqueKeysWithValues: records.map { ($0.id, ShapeID()) })
        let pasted = editor.transact { transaction -> [ShapeID] in
            let context = transaction.shapes
            for record in records {
                var copy = record.copy(as: copies[record.id]!).remappingReferences({ copies[$0] }, in: context)
                copy.meta[CopiedFrom.self] = CopySource(shape: record.id)
                transaction.insert(copy)
            }
            let ids = records.compactMap { copies[$0.id] }.filter { transaction.document[$0] != nil }
            if let offset = offset(placing: ids, in: transaction.shapes) { transaction.translate(Set(ids), by: offset) }
            return ids
        }
        editor.selectedShapeIDs = pasted
    }

    /// How far to move just-pasted shapes: nowhere if any of them is in view (or the view has no
    /// size to tell), else so they're centered in it.
    private func offset(placing ids: [ShapeID], in shapes: ShapeContext) -> CGPoint? {
        let size = editor.viewportSize
        guard size.width > 0, size.height > 0 else { return nil }
        let view = editor.camera.toWorld(CGRect(origin: .zero, size: size))
        let rects = ids.compactMap { shapes.geometry(of: $0) }.filter { !$0.outline.isEmpty && !$0.bounds.isNull }.map(\.bounds)
        guard let first = rects.first else { return nil }
        // Touching counts: a straight line's bounds have no height.
        guard !rects.contains(where: { $0.minX <= view.maxX && $0.maxX >= view.minX && $0.minY <= view.maxY && $0.maxY >= view.minY })
        else { return nil }
        return view.center - rects.dropFirst().reduce(first) { $0.union($1) }.center
    }
}

extension ClipboardState: EditorService {}

extension CanvasEditor {
    var clipboard: ClipboardState? { service(ClipboardState.self) }

    /// Whether the shape is there and its kind's rule (`ShapeCopyability`) lets it be copied.
    /// Without the Clipboard plugin, false.
    public func isCopyable(_ id: ShapeID) -> Bool {
        guard let record = document[id], let clipboard else { return false }
        return clipboard.isCopyable(record)
    }

    /// Whether ⌘C would copy anything: some selected shape can be copied.
    public var canCopy: Bool { clipboard?.canCopy(selectedShapeIDs) ?? false }

    /// Whether ⌘X would cut anything: as `canCopy`, but not mid-gesture.
    public var canCut: Bool { session == nil && canCopy }

    /// Whether ⌘V would paste: the pasteboard holds this app's shapes, and nothing is under way.
    public var canPaste: Bool { session == nil && clipboard?.hasShapes == true }

    /// ⌘C: puts copies of the selected shapes that can be copied on the pasteboard.
    public func copySelection() { copy(selectedShapeIDs) }

    /// ⌘X: copies the selected shapes that can be copied, then deletes them. Does nothing mid-gesture.
    public func cutSelection() { cut(selectedShapeIDs) }

    /// Copies the shapes of `ids` that can be copied, and returns them, back to front. Shapes they
    /// name that aren't copied with them are let go of in the copy (an arrow's end stays where it
    /// is drawn).
    @discardableResult
    public func copy(_ ids: [ShapeID]) -> [ShapeID] { clipboard?.copy(ids) ?? [] }

    /// Copies the shapes of `ids` that can be copied, then deletes them, in one transaction. Does
    /// nothing mid-gesture.
    public func cut(_ ids: [ShapeID]) {
        guard session == nil else { return }
        clipboard?.cut(ids)
    }

    /// ⌘V: copies of what was copied, selected, with new ids (see `CopiedFrom`). Ends editing;
    /// does nothing mid-gesture, or with no shapes on the pasteboard.
    public func paste() {
        guard canPaste else { return }
        clipboard?.paste()
    }
}
