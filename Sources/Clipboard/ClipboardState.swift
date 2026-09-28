import AppKit
import Canvas
import Geometry
import Selection

/// Per editor: the copyability rules, gathered once (the registry is frozen), and what copying,
/// cutting and pasting do. Plugins reach them through `CanvasEditor`'s members below.
///
/// What goes on the pasteboard is a small file (`BoardCodec`): the copied shapes back to front, each
/// kind at its version, so a paste into a newer app migrates them as opening a board would; and
/// under each copied shape that owns a board (`BoardOwning`), what it holds, and so on down, under
/// the original ids. A copied shape names only shapes copied with it: copying lets go of the rest
/// (`ShapeReferencing`), as tldraw's copy does, on each board.
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
    private var content: (changeCount: Int, file: CanvasFile)?

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
    /// by `rename` if it's one of them; otherwise a binding is let go of, and a name is renamed by
    /// `naming` (a shape copied with them on another board of the tree), else kept. A record whose
    /// kind can't let go of a shape it's bound to (one `context` doesn't have) is left out, and
    /// then so may be those bound to it.
    private func carry(_ records: [AnyShapeRecord], renaming rename: (ShapeID) -> ShapeID, naming: (ShapeID) -> ShapeID? = { _ in nil },
                       in context: ShapeContext) -> [AnyShapeRecord] {
        var kept = Set(records.map(\.id))
        restart: while true {
            var carried: [AnyShapeRecord] = []
            for record in records where kept.contains(record.id) {
                guard let remapped = record.remappingReferences({ kept.contains($0) ? rename($0) : nil },
                                                                naming: { kept.contains($0) ? rename($0) : naming($0) }, in: context) else {
                    kept.remove(record.id)
                    continue restart          // those carried already may name it
                }
                carried.append(remapped)
            }
            return carried
        }
    }

    /// Whether the shape's board is one the app shows: its kind owns boards (`BoardOwning`). A board
    /// any other shape has in the file is kept there, never copied or pasted.
    private func ownsBoard(_ record: AnyShapeRecord) -> Bool { editor.registry.boardOwningKinds.contains(record.kind) }

    /// The boards under `owner`, breadth first, by owner: on each, the shapes `keeping` keeps,
    /// carried on their board, and under each of those that owns a board, what it holds. A shape
    /// left out takes the boards under it with it. `isWhole` is whether nothing was left out: no
    /// shape, and no board of a shape that doesn't own boards.
    private func boards(under owner: AnyShapeRecord, reading board: (ShapeID) -> CanvasDocument,
                        keeping: (AnyShapeRecord) -> Bool) -> (boards: [ShapeID: CanvasDocument], isWhole: Bool) {
        var boards: [ShapeID: CanvasDocument] = [:], isWhole = true
        var owners = [owner], next = 0
        while next < owners.count {
            let owner = owners[next]
            next += 1
            let document = board(owner.id)
            guard !document.shapes.isEmpty else { continue }
            guard ownsBoard(owner) else {
                isWhole = false
                continue
            }
            let kept = carry(document.shapes.filter(keeping), renaming: { $0 },
                             in: ShapeContext(document: document, registry: editor.registry))
            if kept.count != document.shapes.count { isWhole = false }
            guard !kept.isEmpty else { continue }
            boards[owner.id] = CanvasDocument(shapes: kept)
            owners += kept
        }
        return (boards, isWhole)
    }

    /// Puts copies of the copyable shapes of `ids` on the pasteboard, in place of what was there,
    /// with what those that own boards hold. Returns the shapes copied, back to front, and those of
    /// them copied whole (with everything under them); with none, the pasteboard is left as it was.
    private func copyReportingWhole(_ ids: [ShapeID]) -> (copied: [ShapeID], whole: Set<ShapeID>) {
        let copied = carry(copyable(ids), renaming: { $0 }, in: editor.shapeContext)
        guard !copied.isEmpty else { return ([], []) }
        var children: [ShapeID: CanvasDocument] = [:], whole: Set<ShapeID> = []
        for record in copied {
            let under = boards(under: record, reading: { editor.contents(of: BoardID(owner: $0)) }, keeping: isCopyable)
            children.merge(under.boards) { old, _ in old }
            if under.isWhole { whole.insert(record.id) }
        }
        let file = CanvasFile(root: CanvasDocument(shapes: copied), children: children)
        let data: Data
        do {
            data = try codec.encode(file)
        } catch {
            assertionFailure("copied shapes don't encode: \(error)")
            return ([], [])
        }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.shapesType)
        content = (pasteboard.changeCount, file)
        return (copied.map(\.id), whole)
    }

    /// Puts copies of the copyable shapes of `ids` on the pasteboard, in place of what was there.
    /// Returns the shapes copied, back to front; with none, the pasteboard is left as it was.
    @discardableResult
    func copy(_ ids: [ShapeID]) -> [ShapeID] { copyReportingWhole(ids).copied }

    /// Copies, then deletes what it copied whole, in one transaction: what can't be copied stays, and
    /// so does a shape holding a board where something couldn't be.
    func cut(_ ids: [ShapeID]) {
        let whole = copyReportingWhole(ids).whole
        guard !whole.isEmpty else { return }
        editor.transact("Cut") { $0.delete(whole) }
        editor.hovered = nil
    }

    /// What a paste would put down, as it's on the pasteboard: this app's shapes (anything else there
    /// is left alone), less those this app can't read (a kind it doesn't install, a newer version of
    /// one, a board format it doesn't know) and those that can't do without them; and under each
    /// that owns a board here, what it holds, read the same way. Read again only when the pasteboard
    /// has changed.
    private func pasteable() -> CanvasFile {
        let changeCount = pasteboard.changeCount
        if let content, content.changeCount == changeCount { return content.file }
        var file = CanvasFile()
        if let data = pasteboard.data(forType: Self.shapesType), let board = try? codec.decode(data) {
            let readable = { (record: AnyShapeRecord) in !record.isOpaque }
            let root = carry(board.file.root.shapes.filter(readable), renaming: { $0 },
                             in: ShapeContext(document: board.file.root, registry: editor.registry))
            var children: [ShapeID: CanvasDocument] = [:]
            for record in root {
                children.merge(boards(under: record, reading: { board.file[BoardID(owner: $0)] }, keeping: readable).boards) { old, _ in old }
            }
            file = CanvasFile(root: CanvasDocument(shapes: root), children: children)
        }
        content = (changeCount, file)
        return file
    }

    /// Whether a paste would put anything down.
    var hasShapes: Bool { !pasteable().root.shapes.isEmpty }

    /// Copies of the shapes on the pasteboard, on top of the board with new ids, then selected
    /// (tldraw's paste). They land where their originals were if any of them would be in view
    /// there, and otherwise centered in the view. A copy of a shape that owns a board goes in with
    /// copies of what it holds, new ids all the way down. Each copy's `CopiedFrom` names its original.
    /// A name (`ShapeNaming`) of a shape pasted with it, on any board of what's pasted, names that
    /// shape's copy; a name of anything else is kept.
    func paste() {
        let file = pasteable()
        let shapes = file.root.shapes
        guard !shapes.isEmpty else { return }
        editor.endEditing()
        var copies: [ShapeID: ShapeID] = [:]
        for board in [file.root] + file.children.values {
            for record in board.shapes { copies[record.id] = ShapeID() }
        }
        let pasted = editor.transact("Paste") { transaction -> [ShapeID] in
            for record in carry(shapes, renaming: { copies[$0]! }, naming: { copies[$0] }, in: transaction.shapes) {
                transaction.insert(pastedCopy(of: record, as: copies[record.id]!),
                                   contents: pastedBoards(under: record.id, in: file, renaming: copies))
            }
            let ids = shapes.compactMap { copies[$0.id] }.filter { transaction.document[$0] != nil }
            if let offset = offset(placing: ids, in: transaction.shapes) { transaction.translate(Set(ids), by: offset) }
            return ids
        }
        editor.selectedShapeIDs = pasted
    }

    /// `record` under a new id, naming the shape it's a copy of.
    private func pastedCopy(of record: AnyShapeRecord, as id: ShapeID) -> AnyShapeRecord {
        var copy = record.copy(as: id)
        copy.meta[CopiedFrom.self] = CopySource(shape: record.id)
        return copy
    }

    /// Copies of the boards under `owner` in `file`, each under its owner's copy, their shapes'
    /// copies naming each other's (`copies`).
    private func pastedBoards(under owner: ShapeID, in file: CanvasFile, renaming copies: [ShapeID: ShapeID]) -> [ShapeID: CanvasDocument] {
        var boards: [ShapeID: CanvasDocument] = [:]
        var owners = [owner], next = 0
        while next < owners.count {
            let owner = owners[next]
            next += 1
            guard let board = file.children[owner] else { continue }
            let carried = carry(board.shapes, renaming: { copies[$0]! }, naming: { copies[$0] },
                                in: ShapeContext(document: board, registry: editor.registry))
            boards[copies[owner]!] = CanvasDocument(shapes: carried.map { pastedCopy(of: $0, as: copies[$0.id]!) })
            owners += carried.map(\.id)
        }
        return boards
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

extension ClipboardState: EditorService {
    /// Nothing kept per shape, so nothing to follow to another board.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

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

    /// ⌘X: copies the selected shapes that can be copied, then deletes those copied whole (`cut`).
    /// Does nothing mid-gesture.
    public func cutSelection() { cut(selectedShapeIDs) }

    /// Copies the shapes of `ids` that can be copied, and returns them, back to front. Shapes they
    /// name that aren't copied with them are let go of in the copy (an arrow's end stays where it
    /// is drawn); a shape that can't let go of one (it can't find it) isn't copied. A shape that
    /// owns a board is copied with what the board holds that can be copied, all the way down.
    @discardableResult
    public func copy(_ ids: [ShapeID]) -> [ShapeID] { clipboard?.copy(ids) ?? [] }

    /// Copies the shapes of `ids` that can be copied, then deletes those copied whole, in one
    /// transaction: a shape whose board, or a board under it, holds one that couldn't be copied
    /// stays. Does nothing mid-gesture.
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
