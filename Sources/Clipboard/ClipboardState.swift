import AppKit
import Canvas
import Geometry
import Grouping
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
///
/// A container copied (`ShapeContaining`: a frame) takes what it holds, at any depth, as an owner
/// takes its board: each copy keeps the container it's in among what's copied, and one whose
/// container isn't copied is in none. A paste puts its copies in the containers they came in, then
/// settles what it put down by the in-or-out rule (`Transaction.settle`), where it lands. Copies
/// that shared a group (Grouping's) are a group of their own, under a new id, on each board, and a
/// group only one of them was in is none of theirs (`BoardGroups.copied`); a shape a cut moves
/// keeps its groups, as it keeps its id.
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

    /// The shapes of `ids` that can be copied, back to front, each once, with what the containers
    /// among them hold (a frame's contents), at any depth, that can be copied.
    private func copyable(_ ids: [ShapeID]) -> [AnyShapeRecord] {
        let document = editor.document, kinds = editor.registry.containingKinds
        var indices: Set<Int> = []
        for id in Set(ids) {
            guard let index = document.index(of: id), isCopyable(document.shapes[index]) else { continue }
            indices.insert(index)
            guard !kinds.isEmpty else { continue }
            for held in document.descendants(of: id, containingKinds: kinds) {
                if let at = document.index(of: held), isCopyable(document.shapes[at]) { indices.insert(at) }
            }
        }
        return indices.sorted().map { document.shapes[$0] }
    }

    /// `records`, from `document`, each in the container it's in there only if that's one of them
    /// too: a copy is in the container it was copied with, and in none if that one isn't copied, so
    /// what's written is whole, and holds no container a board doesn't need.
    private func keepingContainers(_ records: [AnyShapeRecord], of document: CanvasDocument) -> [AnyShapeRecord] {
        let kinds = editor.registry.containingKinds
        var copied: Set<ShapeID>?
        return records.map { record in
            guard let named = record.container else { return record }
            let ids = copied ?? Set(records.map(\.id))
            copied = ids
            let kept = document.container(of: record, containingKinds: kinds).flatMap { ids.contains($0) ? $0 : nil }
            return kept == named ? record : record.copy(as: record.id, container: kept)
        }
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
            let kept = keepingContainers(carry(document.shapes.filter(keeping), renaming: { $0 },
                                               in: ShapeContext(document: document, registry: editor.registry)), of: document)
            if kept.count != document.shapes.count { isWhole = false }
            guard !kept.isEmpty else { continue }
            boards[owner.id] = CanvasDocument(shapes: kept)
            owners += kept
        }
        return (boards, isWhole)
    }

    /// The copyable shapes of `ids` as a small file, with what those that own boards hold and what the
    /// containers among them hold, and those of them copied whole (with everything under them: a
    /// container is whole without what it holds, which a deletion leaves); nil with none.
    private func gather(_ ids: [ShapeID]) -> (file: CanvasFile, copied: [ShapeID], whole: Set<ShapeID>)? {
        let copied = keepingContainers(carry(copyable(ids), renaming: { $0 }, in: editor.shapeContext), of: editor.document)
        guard !copied.isEmpty else { return nil }
        var children: [ShapeID: CanvasDocument] = [:], whole: Set<ShapeID> = []
        for record in copied {
            let under = boards(under: record, reading: { editor.contents(of: BoardID(owner: $0)) }, keeping: isCopyable)
            children.merge(under.boards) { old, _ in old }
            if under.isWhole { whole.insert(record.id) }
        }
        return (CanvasFile(root: CanvasDocument(shapes: copied), children: children), copied.map(\.id), whole)
    }

    /// Puts copies of the copyable shapes of `ids` on the pasteboard, in place of what was there,
    /// with what those that own boards hold, and what the containers among them hold, marked as a
    /// cut's if `cut`. Returns the shapes copied, back to front, and those of them copied whole; with
    /// none, the pasteboard is left as it was.
    private func copyReportingWhole(_ ids: [ShapeID], cut: Bool) -> (copied: [ShapeID], whole: Set<ShapeID>) {
        guard let gathered = gather(ids) else { return ([], []) }
        let file = gathered.file
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
        return (gathered.copied, gathered.whole)
    }

    /// Puts copies of the copyable shapes of `ids` on the board as a paste puts them, without the
    /// pasteboard (it is not touched), selected, `offset` from where they are, in one step,
    /// "Duplicate". Returns the copies, back to front (those not in another copy's container); none
    /// for nothing that can be copied, or a container that takes nothing.
    @discardableResult
    func duplicate(_ ids: [ShapeID], offset: CGPoint) -> [ShapeID] {
        guard let gathered = gather(ids) else { return [] }
        return place(gathered.file, isCut: false, named: "Duplicate", at: nil, offsetBy: offset)
    }

    /// Puts copies of the copyable shapes of `ids` on the pasteboard, in place of what was there.
    /// Returns the shapes copied, back to front; with none, the pasteboard is left as it was.
    @discardableResult
    func copy(_ ids: [ShapeID]) -> [ShapeID] { copyReportingWhole(ids, cut: false).copied }

    /// The shapes of the board a copy of `ids` would take, back to front, which Copy as Image draws;
    /// nil when none of them can be copied. The pasteboard is not touched.
    func shapes(copying ids: [ShapeID]) -> [ShapeID]? { gather(ids)?.copied }

    /// Copies, marked as a cut's, then deletes what it copied whole, in one transaction: what can't
    /// be copied stays, and so does a shape holding a board where something couldn't be (their ids
    /// are in use, so a paste copies them). A container goes with what it holds that was copied;
    /// what it holds that couldn't be stays, let go of (the core's deletion).
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
    /// centered on `point` (world units) when there is one (the context menu's Paste, at its
    /// click); else where they were copied from if any of them would be in view there, and
    /// otherwise centered in the view. A shape that owns a board goes in with what it holds, all
    /// the way down, and a container with what it holds, each in the container it came in.
    ///
    /// What a copy put there pastes as copies, with new ids, each copy's `CopiedFrom` naming its
    /// original. What a cut put there moves: each shape keeps its id if nothing in the file goes by
    /// it (`isUnused`: the shapes a cut took, until they're pasted), and its `CopiedFrom` stays as
    /// it was, since it's the same shape; the rest are copies. Either way one map renames every id
    /// on every board of what's pasted: a binding or a name (`ShapeNaming`) of a shape pasted with
    /// it names that shape as pasted, a name of anything else is kept, and a container is the
    /// container as pasted.
    ///
    /// Where it lands, what's pasted is put down as one, by the in-or-out rule
    /// (`Transaction.settle`): into the container holding most of it, nudged in across its edge, or
    /// out of those it reaches into, gliding there; what's selected is what isn't in another shape
    /// pasted with it. A read-only container (a locked frame) takes nothing: a paste it would take
    /// puts nothing down, and services hear the container refused (it shakes).
    func paste(centeredAt point: CGPoint? = nil) {
        let (file, isCut) = pasteable()
        place(file, isCut: isCut, named: "Paste", at: point, offsetBy: nil)
    }

    /// Puts `file`'s shapes down, as `paste` describes: centered on `point`, else where they were copied from
    /// if in view, else centered in the view; or, with `fixed` (a duplicate's), settled where they are and then
    /// moved by it.
    /// Returns the selected copies.
    @discardableResult
    private func place(_ file: CanvasFile, isCut: Bool, named name: String, at point: CGPoint?, offsetBy fixed: CGPoint?) -> [ShapeID] {
        let shapes = file.root.shapes
        guard !shapes.isEmpty else { return [] }
        editor.endEditing()
        let target = editor.file, kinds = editor.registry.containingKinds
        var ids: [ShapeID: ShapeID] = [:]
        for board in [file.root] + file.children.values {
            for record in board.shapes { ids[record.id] = isCut && target.isUnused(record.id) ? record.id : ShapeID() }
        }
        let pasting: (selected: [ShapeID], nudges: [ShapeID: CGPoint])
        do {
            pasting = try editor.transact(name) { transaction -> (selected: [ShapeID], nudges: [ShapeID: CGPoint]) in
                let carried = carry(shapes, renaming: { ids[$0]! }, naming: { ids[$0] }, in: transaction.shapes)
                let groups = copiedGroups(of: carried, renaming: ids)
                for record in carried {
                    transaction.insert(pasted(record, as: ids[record.id]!, renaming: ids, groups: groups),
                                       contents: pastedBoards(under: record.id, in: file, renaming: ids))
                }
                let placed = shapes.compactMap { ids[$0.id] }.filter { transaction.document[$0] != nil }
                let centered = point.flatMap { point in transaction.shapes.bounds(of: placed).map { point - $0.center } }
                // A paste moves what it puts down before it settles it; a duplicate settles it where it is (a
                // container's copy lies over its original and doesn't take it in, the copies go in the
                // containers their originals are in) and then moves it beside the original.
                if fixed == nil, let offset = centered ?? offset(placing: placed, in: transaction.shapes), offset != .zero {
                    transaction.translate(Set(placed), by: offset)
                }
                switch transaction.settle(placed) {
                case .settled(let nudges):
                    if let fixed, fixed != .zero { transaction.translate(Set(placed), by: fixed) }
                    let pastedIDs = Set(placed), document = transaction.document
                    let tops = placed.filter { id in !(document.container(of: id, containingKinds: kinds).map(pastedIDs.contains) ?? false) }
                    return (tops, nudges)
                case .refused(let container):
                    // Thrown, so nothing is put down, and no step is left.
                    throw PasteRefused(container: container)
                }
            }
        } catch let refusal as PasteRefused {
            editor.refuseChanges(to: [refusal.container])
            return []
        } catch {
            assertionFailure("a paste failed: \(error)")
            return []
        }
        editor.selectedShapeIDs = pasting.selected
        editor.glide(pasting.nudges)
        return pasting.selected
    }

    /// What leaves a paste a read-only container would take: nothing goes down.
    private struct PasteRefused: Error {
        let container: ShapeID
    }

    /// `record` under `id`: under its own, the shape itself, moved; under a new one, a copy, naming
    /// the shape it's a copy of, in the groups `groups` gives it (`copiedGroups`). In the container it
    /// came in, as pasted (`ids`), if one.
    private func pasted(_ record: AnyShapeRecord, as id: ShapeID, renaming ids: [ShapeID: ShapeID],
                        groups: [ShapeID: [String]]) -> AnyShapeRecord {
        var shape = record.copy(as: id, container: record.container.flatMap { ids[$0] })
        if id != record.id {
            shape.meta[CopiedFrom.self] = CopySource(shape: record.id)
            if let path = groups[record.id] { shape[GroupsProperty.self] = path }
        }
        return shape
    }

    /// The groups the copies among `records` (one board's, those `ids` gives new ids) are in, by the
    /// id each was copied from: those two or more of them share, under new ids, and none that only
    /// one is in (`BoardGroups.copied`). A shape that keeps its id isn't among them.
    private func copiedGroups(of records: [AnyShapeRecord], renaming ids: [ShapeID: ShapeID]) -> [ShapeID: [String]] {
        var paths: [ShapeID: [String]] = [:]
        for record in records where ids[record.id] != record.id {
            if let path = record[GroupsProperty.self], !path.isEmpty { paths[record.id] = path }
        }
        guard !paths.isEmpty else { return [:] }
        return BoardGroups.copied(paths) { UUID().uuidString }
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
            let groups = copiedGroups(of: carried, renaming: ids)
            boards[ids[owner]!] = CanvasDocument(shapes: carried.map { pasted($0, as: ids[$0.id]!, renaming: ids, groups: groups) })
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

extension ClipboardState: EditorService {}

extension CanvasEditor {
    var clipboard: ClipboardState? { service(ClipboardState.self) }

    /// Whether the shape is there and its kind's rule (`ShapeCopyability`) lets it be copied.
    /// Without the Clipboard plugin, false.
    public func isCopyable(_ id: ShapeID) -> Bool {
        guard let record = document[id], let clipboard else { return false }
        return clipboard.isCopyable(record)
    }

    /// Whether some of these shapes can be copied: what Copy, Cut and Duplicate act on.
    public func canCopy(_ ids: [ShapeID]) -> Bool { clipboard?.canCopy(ids) ?? false }

    /// Whether ⌘V would paste anything: the pasteboard holds this app's shapes, some of which it
    /// can read, nothing is under way, and the board shown takes shapes (not a locked subboard's,
    /// `isBoardReadOnly`).
    public var canPaste: Bool { session == nil && !isBoardReadOnly && clipboard?.hasShapes == true }

    /// Puts copies of the selected shapes that can be copied beside them, as ⌘D does (`duplicateBeside`).
    public func duplicateSelection() { duplicateBeside(selectedShapeIDs) }

    /// Copies the shapes of `ids` that can be copied beside them, `ClipboardStyle.duplicateOffset` view
    /// points down and right, selected, in one step, "Duplicate": what `.duplicate` does to its shapes.
    /// Nothing mid-gesture or on a board that takes no shapes.
    public func duplicateBeside(_ ids: [ShapeID]) {
        guard session == nil else { return }
        let step = ClipboardStyle.duplicateOffset / camera.zoom
        duplicate(ids, offsetBy: CGPoint(x: step, y: step))
    }

    /// Copies the shapes of `ids` that can be copied on the board, selected, `offset` (world units) from
    /// where they are, in one step, "Duplicate", and returns the copies. The pasteboard is not touched.
    /// Allowed mid-gesture, for a drag with ⌥ that carries copies; none for a board that takes nothing.
    @discardableResult
    public func duplicate(_ ids: [ShapeID], offsetBy offset: CGPoint = .zero) -> [ShapeID] {
        guard !isBoardReadOnly else { return [] }
        return clipboard?.duplicate(ids, offset: offset) ?? []
    }

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
    /// editing; does nothing mid-gesture, on a board that takes no shapes (`isBoardReadOnly`), or
    /// with nothing on the pasteboard it can paste.
    public func paste() {
        guard canPaste else { return }
        clipboard?.paste()
    }

    /// The context menu's Paste: as ⌘V, but what's put down lands centered on `point` (world
    /// units), where the menu was asked for, wherever it was copied from.
    public func paste(centeredAt point: CGPoint) {
        guard canPaste else { return }
        clipboard?.paste(centeredAt: point)
    }

    /// ⇧⌘V: as ⌘V, but what's put down lands centered on the pointer (`pointerWorldLocation`) while it's
    /// over the canvas (`isPointerOverCanvas`, and inside the view); otherwise as ⌘V pastes.
    public func pasteAtPointer() {
        guard canPaste else { return }
        let view = CGRect(origin: .zero, size: viewportSize)
        if isPointerOverCanvas, view.contains(camera.toView(pointerWorldLocation)) {
            paste(centeredAt: pointerWorldLocation)
        } else {
            paste()
        }
    }

    /// Whether Copy as Image has anything to draw: some selected shape can be copied, or, with nothing
    /// selected, some shape of the board shown can.
    public var canCopyAsImage: Bool {
        guard let clipboard else { return false }
        return clipboard.canCopy(selectedShapeIDs.isEmpty ? document.shapes.map(\.id) : selectedShapeIDs)
    }

    /// The shapes Copy as Image draws, back to front: those a copy of the selection would take (what
    /// the containers among them hold too), or, with nothing selected, every shape of the board shown
    /// that can be copied (so what the board keeps aside, and a kind that is `uncopyable`, aren't
    /// drawn). None with none. The pasteboard is not touched.
    public func imageShapes() -> [ShapeID] {
        clipboard?.shapes(copying: selectedShapeIDs.isEmpty ? document.shapes.map(\.id) : selectedShapeIDs) ?? []
    }
}
