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
/// the original ids. A copied shape is bound only to shapes copied with it: copying lets go of the
/// rest (`ShapeReferencing`), as tldraw's copy does, on each board; its names (`ShapeNaming`) are
/// kept.
///
/// A cut marks what it puts there as a cut's: a token beside the shapes, in the same write, which
/// any later write clears (a copy writes none, nor does any other app). Pasted, what a cut took
/// moves: each shape keeps its id if nothing in the file goes by it (`CanvasFile.isUnused`), so
/// whatever names it (a mention) names it again, on whatever board it lands. The first paste's
/// shapes hold the ids, so pasting again copies; undoing that paste frees them.
@MainActor
final class ClipboardState {
    /// This app's shapes on a pasteboard.
    static let shapesType = NSPasteboard.PasteboardType("com.example.InfiniteCanvas.shapes")
    /// The mark of a cut, beside the shapes: a token, fresh each cut. An app that doesn't know it
    /// pastes copies.
    static let cutType = NSPasteboard.PasteboardType("com.example.InfiniteCanvas.cut")

    private unowned let editor: CanvasEditor
    private let pasteboard: NSPasteboard
    /// Each kind's rule (`ShapeCopyability`), found once.
    private let rules: [ShapeKind: @MainActor (AnyShapeRecord) -> Bool]
    private let codec: BoardCodec
    /// What would paste, and whether a cut put it there, as of the pasteboard's change count when
    /// it was last read.
    private var content: (changeCount: Int, file: CanvasFile, isCut: Bool)?

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
    /// with what those that own boards hold, marked as a cut's if `cut`. Returns the shapes copied,
    /// back to front, and those of them copied whole (with everything under them); with none, the
    /// pasteboard is left as it was.
    private func copyReportingWhole(_ ids: [ShapeID], cut: Bool) -> (copied: [ShapeID], whole: Set<ShapeID>) {
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
        if cut { pasteboard.setString(UUID().uuidString, forType: Self.cutType) }
        content = (pasteboard.changeCount, file, cut)
        return (copied.map(\.id), whole)
    }

    /// Puts copies of the copyable shapes of `ids` on the pasteboard, in place of what was there.
    /// Returns the shapes copied, back to front; with none, the pasteboard is left as it was.
    @discardableResult
    func copy(_ ids: [ShapeID]) -> [ShapeID] { copyReportingWhole(ids, cut: false).copied }

    /// Copies, marked as a cut's, then deletes what it copied whole, in one transaction: what can't
    /// be copied stays, and so does a shape holding a board where something couldn't be (their ids
    /// are in use, so a paste copies them).
    func cut(_ ids: [ShapeID]) {
        let whole = copyReportingWhole(ids, cut: true).whole
        guard !whole.isEmpty else { return }
        editor.transact("Cut") { $0.delete(whole) }
        editor.hovered = nil
    }

    /// What a paste would put down, as it's on the pasteboard: this app's shapes (anything else there
    /// is left alone), less those this app can't read (a kind it doesn't install, a newer version of
    /// one, a board format it doesn't know) and those that can't do without them; and under each
    /// that owns a board here, what it holds, read the same way; and whether a cut put it there.
    /// Read again only when the pasteboard has changed.
    private func pasteable() -> (file: CanvasFile, isCut: Bool) {
        let changeCount = pasteboard.changeCount
        if let content, content.changeCount == changeCount { return (content.file, content.isCut) }
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
        let isCut = pasteboard.string(forType: Self.cutType) != nil
        content = (changeCount, file, isCut)
        return (file, isCut)
    }

    /// Whether a paste would put anything down.
    var hasShapes: Bool { !pasteable().file.root.shapes.isEmpty }

    /// The shapes on the pasteboard, on top of the board, then selected (tldraw's paste). They land
    /// where they were copied from if any of them would be in view there, and otherwise centered in
    /// the view. A shape that owns a board goes in with what it holds, all the way down.
    ///
    /// What a copy put there pastes as copies, with new ids, each copy's `CopiedFrom` naming its
    /// original. What a cut put there moves: each shape keeps its id if nothing in the file goes by
    /// it (`isUnused`: the shapes a cut took, until they're pasted), and its `CopiedFrom` stays as
    /// it was, since it's the same shape; the rest are copies. Either way one map renames every id
    /// on every board of what's pasted: a binding or a name (`ShapeNaming`) of a shape pasted with
    /// it names that shape as pasted, and a name of anything else is kept.
    func paste() {
        let (file, isCut) = pasteable()
        let shapes = file.root.shapes
        guard !shapes.isEmpty else { return }
        editor.endEditing()
        let target = editor.file
        var ids: [ShapeID: ShapeID] = [:]
        for board in [file.root] + file.children.values {
            for record in board.shapes { ids[record.id] = isCut && target.isUnused(record.id) ? record.id : ShapeID() }
        }
        let pastedIDs = editor.transact("Paste") { transaction -> [ShapeID] in
            for record in carry(shapes, renaming: { ids[$0]! }, naming: { ids[$0] }, in: transaction.shapes) {
                transaction.insert(pasted(record, as: ids[record.id]!), contents: pastedBoards(under: record.id, in: file, renaming: ids))
            }
            let placed = shapes.compactMap { ids[$0.id] }.filter { transaction.document[$0] != nil }
            if let offset = offset(placing: placed, in: transaction.shapes) { transaction.translate(Set(placed), by: offset) }
            return placed
        }
        editor.selectedShapeIDs = pastedIDs
    }

    /// `record` under `id`: under its own, the shape itself, moved; under a new one, a copy, naming
    /// the shape it's a copy of.
    private func pasted(_ record: AnyShapeRecord, as id: ShapeID) -> AnyShapeRecord {
        var shape = record.copy(as: id)
        if id != record.id { shape.meta[CopiedFrom.self] = CopySource(shape: record.id) }
        return shape
    }

    /// The boards under `owner` in `file` as pasted, each under its owner's id as pasted (`ids`),
    /// their shapes naming each other as pasted.
    private func pastedBoards(under owner: ShapeID, in file: CanvasFile, renaming ids: [ShapeID: ShapeID]) -> [ShapeID: CanvasDocument] {
        var boards: [ShapeID: CanvasDocument] = [:]
        var owners = [owner], next = 0
        while next < owners.count {
            let owner = owners[next]
            next += 1
            guard let board = file.children[owner] else { continue }
            let carried = carry(board.shapes, renaming: { ids[$0]! }, naming: { ids[$0] },
                                in: ShapeContext(document: board, registry: editor.registry))
            boards[ids[owner]!] = CanvasDocument(shapes: carried.map { pasted($0, as: ids[$0.id]!) })
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

    /// Copies the shapes of `ids` that can be copied, and returns them, back to front. Shapes they're
    /// bound to that aren't copied with them are let go of in the copy (an arrow's end stays where
    /// it is drawn); a shape that can't let go of one (it can't find it) isn't copied. Names
    /// (`ShapeNaming`: a mention) are kept. A shape that owns a board is copied with what the board
    /// holds that can be copied, all the way down.
    @discardableResult
    public func copy(_ ids: [ShapeID]) -> [ShapeID] { clipboard?.copy(ids) ?? [] }

    /// Copies the shapes of `ids` that can be copied, as a cut, then deletes those copied whole, in
    /// one transaction: a shape whose board, or a board under it, holds one that couldn't be copied
    /// stays. Pasted, what it deleted moves back in under the ids it had (see `paste`). Shapes bound
    /// to what it deletes let go of it here, and a move doesn't bind them again; names of it (a
    /// mention) are kept, and name it again once it's pasted. Does nothing mid-gesture.
    public func cut(_ ids: [ShapeID]) {
        guard session == nil else { return }
        clipboard?.cut(ids)
    }

    /// ⌘V: puts down what's on the pasteboard, selected: what was copied as copies, with new ids
    /// (see `CopiedFrom`); what was cut moved, each shape under the id it had, unless something in
    /// the file goes by it now (a shape an earlier paste put there), where it's a copy. Ends
    /// editing; does nothing mid-gesture, or with nothing on the pasteboard it can paste.
    public func paste() {
        guard canPaste else { return }
        clipboard?.paste()
    }
}
