import Canvas
import Titles
import Topology
import Validation

/// Boards' warning, as a Validation rule: a warning on each titled shape whose path another shape in
/// the file also has, about its `title` where Titles keeps it (none for a derived title). A shape is
/// told apart from the others by its path (`ShapePath`: the names of the containers it is inside,
/// outermost first, then its title; the root never on it), so two shapes may share a title where their
/// paths differ ("index.ts" in two folder frames), and two of one path are found by it no longer. In
/// no container a path is a title, and the warning says so: “Checkout” is another shape’s title too.;
/// nested, it says the path, placeholders and all: “Alpha › Checkout” is another shape’s path too.
/// Titles as Titles reads them (`registry.title(of:)`: named or derived, folded), containers as every
/// path names them (`registry.containerName(of:)`: an untitled one by its placeholder, so two "A"s in
/// two untitled frames share a path), compared exactly; an untitled note's first line is no title.
/// On every board the editor can show, but shapes kept aside. A warning, never an error: each shape
/// is fine alone.
///
/// The paths are the file's, in an index of its own (`PathIndex`), read as the editor opens and kept
/// up to date by each commit, so the rule reads no other shape: it names, with `affected`, the shapes
/// whose warning a commit may change though the commit didn't change them (a frame renamed reaches
/// what is inside it), which Validation checks again, on the board shown or once theirs is. Where
/// shapes are on a board is nothing it reads, so it ignores moves: a frame dragged with what it holds
/// changes no path. Writes that have not committed (a run of `canvas draw`) are answered too, over the
/// reading the run leaves (`PathIndex.sharedKey(of:in:)`), and `touches` names the other holders of a
/// path the run gives a shape or takes from one. A plugin of its own, so a list can have Boards without
/// Validation (the registry refuses its rule where Validation isn't installed); it reads the
/// containment tree from Topology, without which every shape is in no container.
public struct PathValidationPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "path-validation" }

    #if DEBUG
    /// How many titled shapes the rule has checked in this process, debug builds only: tests hold a
    /// move, and a frame's drag with what it holds, to checking none.
    @MainActor public private(set) static var pathsChecked = 0
    #endif

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { PathIndex(editor: $0) }
        registrar.forShapes(adopting: .titled) { titled in
            titled.validate(ignoringMoves: true, affected: { changes, editor in
                editor.pathIndex?.affected(by: changes) ?? []
            }, touches: { changes, shapes in
                // Writes that have not committed (a run's): the other holders of a path they give a shape or take from
                // one, and what is inside a container they rename or put elsewhere.
                guard let reading = shapes.reading, let index = reading.service(PathIndex.self) else { return [] }
                return index.touched(by: changes, reading: reading)
            }) { shape, context in
                guard context.registry.title(of: shape) != nil else { return [] }
                // Without an editor (a run's check, before it commits) the index is asked through the reading the shapes
                // have, for the paths as the run leaves them.
                let shared: ShapePath.Key?
                if let index = context.service(PathIndex.self) {
                    shared = index.sharedKey(of: shape.id)
                } else if let reading = context.reading, let index = reading.service(PathIndex.self) {
                    shared = index.sharedKey(of: shape, in: reading)
                } else {
                    return []
                }
                #if DEBUG
                Self.pathsChecked += 1
                #endif
                guard let shared else { return [] }
                let named = context.registry.properties(for: shape.kind).contains(TitleProperty.key)
                return [.warning(Self.message(shared), field: named ? TitleProperty.key.rawValue : nil)]
            }
        }
    }

    /// What the warning says of a path two shapes share: a title's sentence in no container, a path's
    /// in one.
    static func message(_ key: ShapePath.Key) -> String {
        key.isTopLevel ? "“\(key.name)” is another shape’s title too." : "“\(key.text)” is another shape’s path too."
    }
}

/// Every titled shape's path in the file, and the shapes each path names, on every board the editor
/// can show, but shapes kept aside: read whole as the editor opens (and again for a file put in
/// place), as Mentions' catalog is, so no check pays for it (a query's slice), then kept up to date by
/// each commit, for what it changed on any board, never for a move. It never transacts.
///
/// A path changes when the shape's title does, when it's put in a container or taken out of one, and
/// when a container it is inside, at any depth, is renamed, titled or untitled, put in another
/// container or taken out, moved to another board, turned into another kind or deleted (what it held
/// falling into its own container). So beside each titled shape's path the index keeps every
/// container's parent and name as the last commit left them (`links`), and a commit that changes
/// either for a container files again every titled shape inside it (Topology's `descendants(of:)`),
/// each shape once a commit, by the title its kept path ends in (the commit didn't change it), its path
/// made through the containers' names kept by `ShapePaths`, each container's once a commit. A commit that only moves shapes (`ChangeSet.moved`) changes no path: a
/// frame dragged with what it holds keeps what it holds, and a shape dropped into a frame is changed
/// (its container), not moved.
@MainActor
public final class PathIndex {
    private unowned let editor: CanvasEditor
    /// The containers' names and parents, kept between commits.
    private var paths: ShapePaths
    /// Each titled shape's path.
    public private(set) var keys: [ShapeID: ShapePath.Key] = [:]
    /// The shapes each path names.
    private var holders: [ShapePath.Key: Set<ShapeID>] = [:]
    /// Each container's parent and name as the last commit left them: what a commit's are compared with.
    private var links: [ShapeID: Link] = [:]
    /// The shapes whose warning the last commit heard may change though it didn't change them.
    private var lastAffected: Set<ShapeID> = []
    /// The kinds whose shapes contain others (`registry.containerKinds`), and those that hold shapes on
    /// their board (`registry.containingKinds`).
    private let containerKinds: Set<ShapeKind>
    private let containingKinds: Set<ShapeKind>
    /// Whether Topology is installed: without it every shape is in no container.
    private let hasTree: Bool
    /// What a container of each kind is called while it has no title.
    private var placeholders: [ShapeKind: String] = [:]

    /// A container's place and name, as a path reads them.
    private struct Link: Equatable {
        var parent: ShapeID?
        var name: String
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        paths = ShapePaths(editor: editor)
        containerKinds = editor.registry.containerKinds
        containingKinds = editor.registry.containingKinds
        hasTree = editor.topology != nil
        read()
    }

    // MARK: Asking

    /// The shapes `key` names now.
    public func holders(of key: ShapePath.Key) -> Set<ShapeID> { holders[key] ?? [] }

    /// A shape's path, if another shape has it too; nil for a shape alone in its path, untitled, or on no
    /// board the editor can show.
    public func sharedKey(of id: ShapeID) -> ShapePath.Key? {
        guard let key = keys[id], let named = holders[key], named.count > 1 else { return nil }
        return key
    }

    /// The shapes a commit may change the warning of though it didn't change them: those it filed under
    /// another path that shared one before it or share one now (a shape alone before and after says nothing
    /// either way), and those it gave a path's first other holder or took its last from; never what it
    /// deleted, so a subboard's deletion names none of what its boards held. Asked once every service has
    /// the commit; asked again for the same commit, the same.
    public func affected(by changes: ChangeSet) -> Set<ShapeID> {
        lastAffected
    }

    // MARK: Following the file

    /// Files the paths a commit changed, noting whose warning that changes.
    private func follow(_ changes: ChangeSet) {
        lastAffected = []
        guard !changes.shapeIDs.isEmpty || !changes.elsewhere.isEmpty else { return }
        paths.forget(changes)
        editor.withoutObservingDocument { apply(changes) }
    }

    /// `follow(_:)`'s filing, the file read without observing it.
    private func apply(_ changes: ChangeSet) {
        // The file read once, each board's showing asked once: a subboard's deletion hands it every shape its
        // boards held (`elsewhere`). Topology looked up through the editor, so it has heard the commit.
        let document = editor.document, shown = editor.board, file = editor.file, topology = editor.topology
        let owning = editor.registry.boardOwningKinds
        // Each board's shapes, if the editor can show it, read once.
        var boards: [BoardID: CanvasDocument?] = [:]
        func current(_ id: ShapeID, elsewhere: Bool) -> Placed? {
            if !elsewhere, let record = document[id] { return Placed(record: record, board: shown, parent: parent(of: record, in: document, on: shown)) }
            guard let board = file.board(containing: id) else { return nil }
            let there: CanvasDocument?
            if let known = boards[board] {
                there = known
            } else {
                there = file.canShow(board, boardOwningKinds: owning) ? file[board] : nil
                boards[board] = there
            }
            return there?[id].map { Placed(record: $0, board: board, parent: parent(of: $0, in: there!, on: board)) }
        }
        var pass = Refiling()
        let registry = editor.registry
        func look(_ id: ShapeID, elsewhere: Bool = false) {
            guard !pass.filed.contains(id) else { return }
            let placed = current(id, elsewhere: elsewhere)
            let title = placed.flatMap { $0.record.isOpaque ? nil : registry.title(of: $0.record) }
            let link = placed.flatMap { isContainer($0.record) ? Link(parent: $0.parent, name: title ?? placeholder(of: $0.record)) : nil }
            if links[id] != link {
                links[id] = link
                // Its name or its place changed, or it's a container now: what's inside it is somewhere else.
                if link != nil { pass.relinked.append(id) }
            }
            place(id, placed, title: title, &pass)
        }
        for id in changes.removed { look(id) }
        for id in changes.added where !changes.moved.contains(id) { look(id) }
        for id in changes.changed where !changes.moved.contains(id) { look(id) }
        // A commit that only took boards (a subboard's deletion) hands over every shape they held, all gone: only
        // those with a path, and the containers, need filing, whichever is fewer to go through. Not one that
        // brought some of them to the board shown as it took their board (undoing a turn, whose move put them
        // there): those aren't gone.
        let onlyTook = !changes.replacedDocument && changes.boardsAdded.isEmpty && changes.boardsChanged.isEmpty
            && changes.added.isDisjoint(with: changes.elsewhere)
        if onlyTook, keys.count + links.count < changes.elsewhere.count {
            for id in keys.keys.filter({ changes.elsewhere.contains($0) }) {
                refile(id, to: nil, isGone: true)
                pass.gone.insert(id)
            }
            links = links.filter { !changes.elsewhere.contains($0.key) }
        } else {
            for id in changes.elsewhere { look(id, elsewhere: true) }
        }
        // What's inside a container whose name or place changed, at any depth, as the tree is now. One the commit
        // didn't file is as it was but for where it is: untitled still, or called what its path ends in.
        for container in pass.relinked {
            for id in topology?.descendants(of: container) ?? [] where !pass.filed.contains(id) {
                guard let title = keys[id]?.name else { continue }
                place(id, current(id, elsewhere: false), title: title, &pass)
            }
        }
        // What the commit deleted is never named, though it was the last other holder of a path when another went.
        if !lastAffected.isEmpty, !pass.gone.isEmpty { lastAffected = lastAffected.filter { !pass.gone.contains($0) } }
    }

    /// A shape in the file as a commit left it: its record, its board, and what it is directly inside.
    private struct Placed {
        let record: AnyShapeRecord
        let board: BoardID
        let parent: ShapeID?
    }

    /// What a shape on `board` is directly inside, as Topology has it (`parent(of:)`), from the board in hand: the
    /// container it's in there, else the board's owner; none without Topology, as the containers' nodes have it.
    private func parent(of record: AnyShapeRecord, in document: CanvasDocument, on board: BoardID) -> ShapeID? {
        guard hasTree else { return nil }
        return document.container(of: record, containingKinds: containingKinds) ?? board.owner
    }

    /// What one commit has filed so far: each shape once, the containers' names along the chains made once.
    private struct Refiling {
        var filed: Set<ShapeID> = []
        var names: [ShapeID: [String]] = [:]
        /// The last container's names asked: what is inside one comes in a row.
        var last: (container: ShapeID?, names: [String])?
        var relinked: [ShapeID] = []
        var gone: Set<ShapeID> = []
    }

    /// Files a shape under its path now, called `title` (none for one gone, untitled or kept aside), once a commit,
    /// noting whose warning that changes.
    private func place(_ id: ShapeID, _ placed: Placed?, title: String?, _ pass: inout Refiling) {
        guard pass.filed.insert(id).inserted else { return }
        var now: ShapePath.Key?
        if let placed, let title {
            let names: [String]
            if let last = pass.last, last.container == placed.parent {
                names = last.names
            } else {
                names = paths.names(through: placed.parent, memo: &pass.names)
                pass.last = (placed.parent, names)
            }
            now = ShapePath.Key(names + [title])
        }
        if placed == nil { pass.gone.insert(id) }
        refile(id, to: now, isGone: placed == nil)
    }

    /// Moves a shape from the path it had to `now`, noting whose warning that changes.
    private func refile(_ id: ShapeID, to now: ShapePath.Key?, isGone: Bool) {
        let before = keys[id]
        guard now != before else { return }
        if let before, let slot = holders.index(forKey: before) {
            let wasShared = holders.values[slot].count > 1
            holders.values[slot].remove(id)
            if wasShared, !isGone { lastAffected.insert(id) }
            if holders.values[slot].count == 1 {
                lastAffected.formUnion(holders.values[slot])
            } else if holders.values[slot].isEmpty {
                holders.remove(at: slot)
            }
        }
        if let now {
            if let others = holders[now], !others.isEmpty {
                if others.count == 1 { lastAffected.formUnion(others) }
                lastAffected.insert(id)
            }
            holders[now, default: []].insert(id)
        }
        keys[id] = now
    }

    /// What a container is called in a path while it has no title (`registry.containerName(of:)`'s placeholder),
    /// asked once a kind.
    private func placeholder(of record: AnyShapeRecord) -> String {
        if let known = placeholders[record.kind] { return known }
        let placeholder = editor.registry.containerName(of: record).placeholder
        placeholders[record.kind] = placeholder
        return placeholder
    }

    /// Whether a shape contains others, as Topology goes by it: of a kind that owns boards or holds shapes, not kept
    /// aside.
    private func isContainer(_ record: AnyShapeRecord) -> Bool {
        !record.isOpaque && containerKinds.contains(record.kind)
    }

    /// Reads every path on every board the editor can show (`editor.showableBoards`).
    private func read() {
        keys = [:]
        holders = [:]
        links = [:]
        paths.forgetAll()
        let registry = editor.registry
        editor.withoutObservingDocument {
            var names: [ShapeID: [String]] = [:]
            for board in editor.showableBoards {
                let document = editor.contents(of: board)
                for record in document.shapes where !record.isOpaque {
                    let parent = parent(of: record, in: document, on: board), title = registry.title(of: record)
                    if containerKinds.contains(record.kind) { links[record.id] = Link(parent: parent, name: title ?? placeholder(of: record)) }
                    guard let title else { continue }
                    let key = ShapePath.Key(paths.names(through: parent, memo: &names) + [title])
                    keys[record.id] = key
                    holders[key, default: []].insert(record.id)
                }
            }
        }
    }

    // MARK: Writes that have not committed

    /// What a run has reached, by the paths its shapes have now: made once for each state of a run's log.
    private var run: Run?

    /// The shapes a run's writes reached (those it wrote, and what is inside a container it renamed or put elsewhere,
    /// as the committed tree has it), their paths as the run leaves them, and under each path the reached shapes it
    /// names now.
    private struct Run {
        var id: Int, writes: Int, revision: Int
        var written: Set<ShapeID> = []
        var reached: Set<ShapeID> = []
        var keys: [ShapeID: ShapePath.Key] = [:]
        var holders: [ShapePath.Key: Set<ShapeID>] = [:]
    }

    /// The run's writes filed by path, for a reading that hasn't committed. O(its writes and what they reach, each by
    /// its depth), once for each state of the log.
    private func reached(in reading: LayoutReading) -> Run {
        if let run, run.id == reading.runID, run.writes == reading.writeCount, run.revision == editor.revision { return run }
        var run = Run(id: reading.runID, writes: reading.writeCount, revision: editor.revision)
        func reach(_ id: ShapeID) {
            guard run.reached.insert(id).inserted else { return }
            guard let record = reading.shape(inFile: id), let key = key(of: record, in: reading) else { return }
            run.keys[id] = key
            run.holders[key, default: []].insert(id)
        }
        for id in reading.changes where run.written.insert(id).inserted {
            reach(id)
            for inside in relinkedContents(of: id, in: reading) { reach(inside) }
        }
        self.run = run
        return run
    }

    /// A shape's path if another shape has it too, as a reading that hasn't committed has the file: the reached shapes
    /// that have it now, and the committed holders the run has not reached and left in the file.
    public func sharedKey(of record: AnyShapeRecord, in reading: LayoutReading) -> ShapePath.Key? {
        guard !reading.isCommitted else { return sharedKey(of: record.id) }
        let run = reached(in: reading), id = record.id
        guard let key = run.reached.contains(id) ? run.keys[id] : keys[id] ?? key(of: record, in: reading) else { return nil }
        if run.holders[key]?.contains(where: { $0 != id }) == true { return key }
        // A committed holder counts if the run has not reached it (written it, renamed what it's in) or taken it (with its board).
        let held = holders[key]?.contains { $0 != id && !run.reached.contains($0) && reading.shape(inFile: $0) != nil } ?? false
        return held ? key : nil
    }

    /// The shapes whose warning writes that have not committed may change though they do not write them: for each
    /// written shape whose path is another now, the committed holders of the path it has (they share it now) and, where
    /// one holder of the path it had is left, that one (it shares it no longer); and for a written container whose name
    /// or place changed, the titled shapes inside it and the same of each. O(the writes and what they reach).
    public func touched(by changes: ChangeSet, reading: LayoutReading) -> Set<ShapeID> {
        guard !reading.isCommitted else { return [] }
        let run = reached(in: reading)
        var found: Set<ShapeID> = []
        func look(_ id: ShapeID) {
            let before = keys[id]
            let now = run.reached.contains(id) ? run.keys[id] : before
            guard before != now else { return }
            if let now, let others = holders[now] { for other in others where !run.reached.contains(other) { found.insert(other) } }
            if let before, let others = holders[before] {
                let left = others.filter { !run.reached.contains($0) }
                if left.count == 1, run.holders[before]?.isEmpty != false { found.formUnion(left) }
            }
        }
        func visit(_ id: ShapeID) {
            look(id)
            for inside in relinkedContents(of: id, in: reading) where keys[inside] != nil || run.keys[inside] != nil {
                found.insert(inside)
                look(inside)
            }
        }
        for id in changes.added { visit(id) }
        for id in changes.changed where !changes.moved.contains(id) { visit(id) }
        for id in changes.removed { visit(id) }
        for id in changes.elsewhere { visit(id) }
        return found.subtracting(run.written)
    }

    /// What is inside a committed container, as the committed tree has it, if a reading has its name or place other
    /// than the commit left them (renamed, put elsewhere, gone); none for any other shape.
    private func relinkedContents(of id: ShapeID, in reading: LayoutReading) -> [ShapeID] {
        guard let before = links[id] else { return [] }
        let now = reading.shape(inFile: id).flatMap { record in
            isContainer(record) ? Link(parent: parent(of: record, in: reading), name: editor.registry.containerName(of: record).text) : nil
        }
        guard now != before else { return [] }
        return editor.withoutObservingDocument { editor.topology?.descendants(of: id) ?? [] }
    }

    /// The shape a record is directly inside as a reading has the file: the container it names, if that is on its
    /// board, holds shapes and isn't kept aside (the core's rule, `CanvasDocument.container(of:containingKinds:)`),
    /// else its board's owner; nil on the root in no container.
    private func parent(of record: AnyShapeRecord, in reading: LayoutReading) -> ShapeID? {
        let board = reading.board(containing: record.id)
        if let id = record.container, record.box != nil, let holder = reading.shape(inFile: id), !holder.isOpaque,
           containingKinds.contains(holder.kind), board == nil || reading.board(containing: id) == board {
            return id
        }
        return board?.owner
    }

    /// A shape's path as a reading has the file, from its records alone: up through each record's container and
    /// each board's owner, each named as a path names it. Nil for an untitled shape, or one kept aside.
    private func key(of record: AnyShapeRecord, in reading: LayoutReading) -> ShapePath.Key? {
        guard !record.isOpaque, let title = editor.registry.title(of: record) else { return nil }
        var segments = [title], met: Set<ShapeID> = [record.id], next = parent(of: record, in: reading)
        while let id = next, met.insert(id).inserted, let above = reading.shape(inFile: id) {
            segments.append(editor.registry.containerName(of: above).text)
            next = parent(of: above, in: reading)
        }
        return ShapePath.Key(segments.reversed())
    }
}

extension PathIndex: EditorService {
    /// Follows the commit.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        follow(changes)
    }

    /// Nothing, but for a file put in place with the switch, whose paths it reads: the paths are the file's, kept up
    /// to date by every commit, whatever board it was on.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        lastAffected = []
        if change.isFileReplaced { read() }
    }
}

extension CanvasEditor {
    /// Boards' index of the file's paths; nil without PathValidationPlugin.
    public var pathIndex: PathIndex? { service(PathIndex.self) }
}
