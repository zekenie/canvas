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
    /// What would paste, as of the pasteboard's change count when it was last read.
    private var content: (changeCount: Int, shapes: [AnyShapeRecord])?

    init(editor: CanvasEditor, pasteboard: NSPasteboard) {
        self.editor = editor
        self.pasteboard = pasteboard
        rules = editor.registry.contributionByKind(to: ShapeCopyability.self)
        codec = BoardCodec(registry: editor.registry)
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

    /// `records`, each shape they're bound to (`ShapeReferencing`) or name (`ShapeNaming`) renamed
    /// by `rename` if it's one of them; otherwise a binding is let go of, and a name is kept. A
    /// record whose kind can't let go of a shape it's bound to (one `context` doesn't have) is left
    /// out, and then so may be those bound to it.
    private func carry(_ records: [AnyShapeRecord], renaming rename: (ShapeID) -> ShapeID,
                       in context: ShapeContext) -> [AnyShapeRecord] {
        var kept = Set(records.map(\.id))
        restart: while true {
            var carried: [AnyShapeRecord] = []
            for record in records where kept.contains(record.id) {
                guard let remapped = record.remappingReferences({ kept.contains($0) ? rename($0) : nil }, in: context) else {
                    kept.remove(record.id)
                    continue restart          // those carried already may name it
                }
                carried.append(remapped)
            }
            return carried
        }
    }

    /// Puts copies of the copyable shapes of `ids` on the pasteboard, in place of what was there.
    /// Returns the shapes copied, back to front; with none, the pasteboard is left as it was.
    @discardableResult
    func copy(_ ids: [ShapeID]) -> [ShapeID] {
        let copied = carry(copyable(ids), renaming: { $0 }, in: editor.shapeContext)
        guard !copied.isEmpty else { return [] }
        let data: Data
        do {
            data = try codec.encode(CanvasDocument(shapes: copied))
        } catch {
            assertionFailure("copied shapes don't encode: \(error)")
            return []
        }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.shapesType)
        content = (pasteboard.changeCount, copied)
        return copied.map(\.id)
    }

    /// Copies, then deletes what it copied, in one transaction: what can't be copied stays.
    func cut(_ ids: [ShapeID]) {
        let copied = copy(ids)
        guard !copied.isEmpty else { return }
        editor.transact("Cut") { $0.delete(Set(copied)) }
        editor.hovered = nil
    }

    /// The shapes a paste would put down, as they're on the pasteboard: this app's shapes (anything
    /// else there is left alone), less those this app can't read (a kind it doesn't install, a
    /// newer version of one, a board format it doesn't know) and those that can't do without them.
    /// Read again only when the pasteboard has changed.
    private func pasteable() -> [AnyShapeRecord] {
        let changeCount = pasteboard.changeCount
        if let content, content.changeCount == changeCount { return content.shapes }
        var shapes: [AnyShapeRecord] = []
        if let data = pasteboard.data(forType: Self.shapesType), let board = try? codec.decode(data) {
            let readable = board.document.shapes.filter { !$0.isOpaque }
            shapes = carry(readable, renaming: { $0 }, in: ShapeContext(document: board.document, registry: editor.registry))
        }
        content = (changeCount, shapes)
        return shapes
    }

    /// Whether a paste would put anything down.
    var hasShapes: Bool { !pasteable().isEmpty }

    /// Copies of the shapes on the pasteboard, on top of the board with new ids, then selected
    /// (tldraw's paste). They land where their originals were if any of them would be in view
    /// there, and otherwise centered in the view. Each one's `CopiedFrom` names its original.
    func paste() {
        let shapes = pasteable()
        guard !shapes.isEmpty else { return }
        editor.endEditing()
        let copies = Dictionary(uniqueKeysWithValues: shapes.map { ($0.id, ShapeID()) })
        let pasted = editor.transact("Paste") { transaction -> [ShapeID] in
            for record in carry(shapes, renaming: { copies[$0]! }, in: transaction.shapes) {
                var copy = record.copy(as: copies[record.id]!)
                copy.meta[CopiedFrom.self] = CopySource(shape: record.id)
                transaction.insert(copy)
            }
            let ids = shapes.compactMap { copies[$0.id] }.filter { transaction.document[$0] != nil }
            if let offset = offset(placing: ids, in: transaction.shapes) { transaction.translate(Set(ids), by: offset) }
            return ids
        }
        editor.selectedShapeIDs = pasted
    }

    /// How far to move just-pasted shapes: nowhere if any of them is in view (touching counts, as
    /// tldraw's does; a straight line's bounds have no height), or the view has no size to tell;
    /// else so they're centered in it.
    private func offset(placing ids: [ShapeID], in shapes: ShapeContext) -> CGPoint? {
        let size = editor.viewportSize
        guard size.width > 0, size.height > 0, let bounds = shapes.bounds(of: ids) else { return nil }
        let view = editor.camera.toWorld(CGRect(origin: .zero, size: size))
        guard !ids.contains(where: { shapes.bounds(of: [$0])?.touches(view) == true }) else { return nil }
        return view.center - bounds.center
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

    /// Whether ⌘V would paste anything: the pasteboard holds this app's shapes, some of which it
    /// can read, and nothing is under way.
    public var canPaste: Bool { session == nil && clipboard?.hasShapes == true }

    /// ⌘C: puts copies of the selected shapes that can be copied on the pasteboard.
    public func copySelection() { copy(selectedShapeIDs) }

    /// ⌘X: copies the selected shapes that can be copied, then deletes them. Does nothing mid-gesture.
    public func cutSelection() { cut(selectedShapeIDs) }

    /// Copies the shapes of `ids` that can be copied, and returns them, back to front. Shapes they
    /// name that aren't copied with them are let go of in the copy (an arrow's end stays where it
    /// is drawn); a shape that can't let go of one (it can't find it) isn't copied.
    @discardableResult
    public func copy(_ ids: [ShapeID]) -> [ShapeID] { clipboard?.copy(ids) ?? [] }

    /// Copies the shapes of `ids` that can be copied, then deletes them, in one transaction. Does
    /// nothing mid-gesture.
    public func cut(_ ids: [ShapeID]) {
        guard session == nil else { return }
        clipboard?.cut(ids)
    }

    /// ⌘V: copies of what was copied, selected, with new ids (see `CopiedFrom`). Ends editing;
    /// does nothing mid-gesture, or with nothing on the pasteboard it can paste.
    public func paste() {
        guard canPaste else { return }
        clipboard?.paste()
    }
}
