import Canvas
import CoreGraphics
import DrawScript
import Foundation
import FuzzyMatching

// Paths as names. A title names a shape while it is the one called that where it is looked for. Where two shapes share a title,
// in different frames or on different subboards' boards, each is named by its path: the containers it is in, outermost first, then
// its title (`"Payments" > "Checkout"`), each part the shape the next is directly inside (a frame's shapes; a subboard's board's
// shapes in no frame, as Topology's `parent(of:)` and `children(of:)` have it). The first part may instead be an id (a container
// with no title) or `board`, the top of the board the run draws on.
//
// A path names every shape whose chain of containers ends with its parts in order (a selector's way): its first part is looked
// up as the title of a frame or a subboard wherever the file has one, and each part after it among what the one before holds.
// Exactly one match is the shape; several are `ambiguous_title`, listed by their paths; none is `unknown_title`. A shape
// statement named by a path restates the shape there, or makes it directly in the path's container, as `in` would put it there,
// which must be on the board already (a container the script draws holds nothing yet: `unsupported`). Everything a path is read
// from is the file's own containers (`CanvasDocument.container(of:containingKinds:)`, `contents(of:)`), so a plugin list without
// Topology reads it alike.

extension FileNames.Container {
    /// The shape that holds, when it is a shape on its own board (a frame), else nil: the top of a board has none.
    var shapeID: ShapeID? {
        if case .shape(let id, _) = self { id } else { nil }
    }
}

extension FileNames {
    /// What a path leads to in the file.
    struct PathMatch {
        /// The shapes the whole path names, with the board each is on.
        var shapes: [Place] = []
        /// The holders the path less its last part leads to: where a shape the path names would be made.
        var holders: [Container] = []
        /// Where it stopped, if it did: the first part nothing matched (0 for the first, then one for each title after it), and the
        /// holders it had reached to that point, whose contents a message may guess from.
        var stoppedAt: Int?
        var reached: [Container] = []
    }

    /// What a shape holds if it is a container: a subboard's board, or a frame (a kind that is both is its board, as
    /// `container(among:)` takes it).
    func holder(_ place: Place) -> Container? {
        guard let record = editor.file.record(place.id), !record.isOpaque else { return nil }
        let registry = editor.registry
        if registry.boardOwningKinds.contains(record.kind) { return .board(BoardID(owner: place.id)) }
        return registry.isContainer(record) ? .shape(place.id, on: place.board) : nil
    }

    /// The shapes directly inside a holder, back to front, each with the board it is on: a frame's, or a board's shapes in no
    /// frame.
    func contents(of holder: Container) -> [Place] {
        let registry = editor.registry, kinds = registry.containingKinds
        switch holder {
        case .board(let board):
            let document = editor.file[board]
            return document.shapes.compactMap { record in
                record.isOpaque || document.container(of: record, containingKinds: kinds) != nil ? nil : (record.id, board)
            }
        case .shape(let id, on: let board):
            return editor.file[board].contents(of: id, containingKinds: kinds).map { ($0, board) }
        case .none, .holdsNone, .ambiguous:
            return []
        }
    }

    /// What a shape is called, if anything.
    func name(of place: Place) -> String? {
        editor.file.record(place.id).flatMap { naming.name($0, editor.registry) }
    }

    /// The shapes whose chain of containers ends with `path`'s parts (folded), each directly inside the one before. `board` is the
    /// board a `board` head means, the one the run draws on.
    func match(_ path: ShapePath, board: BoardID) -> PathMatch {
        var holders: [Container]
        switch path.head {
        case .board:
            holders = [.board(board)]
        case .title(let title):
            holders = (places[title] ?? []).compactMap(holder)
        case .id(let text):
            holders = UUID(uuidString: text).flatMap { place(ofID: ShapeID($0)) }.flatMap(holder).map { [$0] } ?? []
        }
        var found = PathMatch()
        if holders.isEmpty {
            found.stoppedAt = 0
            return found
        }
        for (offset, part) in path.rest.dropLast().enumerated() {
            let next = holders.flatMap(contents(of:)).filter { name(of: $0) == part }.compactMap(holder)
            if next.isEmpty {
                found.stoppedAt = offset + 1
                found.reached = holders
                return found
            }
            holders = next
        }
        found.holders = holders
        found.shapes = holders.flatMap(contents(of:)).filter { name(of: $0) == path.last }
        if found.shapes.isEmpty {
            found.stoppedAt = path.rest.count
            found.reached = holders
        }
        return found
    }

    /// A path with its titles folded, as the plugin that names shapes folds one; nil for a blank title.
    public func folded(_ path: ShapePath) -> ShapePath? {
        Drawing.folded(path, naming: naming)
    }

    /// What a path (folded) names as a shape that holds others, as `container(called:boards:)` says it of a title.
    public func container(path: ShapePath, boards: Bool = false, board: BoardID) -> Container {
        container(among: match(path, board: board).shapes, boards: boards)
    }

    /// What a name as a script writes it (a title, an id or a path) names as a shape that holds others; nil for a title that is
    /// blank. `board` is the board a path's `board` head means.
    public func container(named name: ShapeName, boards: Bool = false, board: BoardID) -> Container? {
        switch name {
        case .title(let written):
            naming.fold(written).map { container(called: $0, boards: boards) }
        case .id(let text):
            UUID(uuidString: text).map { container(withID: ShapeID($0), boards: boards) }
        case .path(let path):
            Drawing.folded(path, naming: naming).map { container(path: $0, boards: boards, board: board) }
        }
    }

    /// The shape a path names, as `shape(called:on:)` finds one a title names: on `board` alone when one is given, else wherever it
    /// is in the file (the board shown's first, else the only other board that has one).
    public func shape(path: ShapePath, on board: BoardID? = nil) -> Found {
        let shapes = match(path, board: board ?? editor.board).shapes
        guard let board else {
            switch beyond(path.last, among: shapes, named: path.written) {
            case .shape(let place): return .shape(place.id, on: place.board)
            case .none: return .none(like: Suggestions.closest(to: path.last, among: titles))
            case .ambiguous(let message, let places): return .ambiguous(message: message, hint: pathHint(for: places))
            }
        }
        let here = shapes.filter { $0.board == board }
        if here.count > 1 { return .ambiguous(message: several(here, path.written, on: called(board)), hint: pathHint(for: here)) }
        if let found = here.first { return .shape(found.id, on: board) }
        if let other = shapes.first { return .elsewhere(other.board) }
        return .none(like: Suggestions.closest(to: path.last, among: entries(on: board).map(\.name)))
    }

    /// Where a shape is, as the path that names it: the containers it is in, outermost first, then its title; nil for a shape
    /// with no title or in no container. The nearest container with no title is named by its id, and the path starts there (a
    /// path whose first part is an id). What a message calls a shape whose title is not its alone.
    func path(of id: ShapeID) -> ShapePath? {
        Drawing.path(of: id, in: editor, naming: naming)
    }
}

extension Drawing {
    // MARK: Naming a shape by where it is

    /// The shapes a shape is inside, the nearest first: the containers it is in on its board, its board's owner, the containers
    /// that one is in, and so on up (Topology's `ancestors(of:)`, read from the file's own containers). Empty on the root in no
    /// container.
    static func containers(above id: ShapeID, in editor: CanvasEditor) -> [ShapeID] {
        let file = editor.file, kinds = editor.registry.containingKinds
        guard let board = file.board(containing: id), board == editor.board || editor.canShow(board) else { return [] }
        var chain = file[board].containers(of: id, containingKinds: kinds)
        var current = board, met: Set<ShapeID> = [id]
        while let owner = current.owner, met.insert(owner).inserted, let above = file.board(containing: owner) {
            chain.append(owner)
            chain += file[above].containers(of: owner, containingKinds: kinds)
            current = above
        }
        return chain
    }

    /// The path of a shape with this title that is inside these containers (nearest first): the shape's, or one a run would
    /// make there. Nil for none.
    static func path(inside chain: [ShapeID], titled title: String, in editor: CanvasEditor, naming: DrawNaming) -> ShapePath? {
        guard !chain.isEmpty else { return nil }
        var titles: [String] = []
        for ancestor in chain {
            if let record = editor.file.record(ancestor), let name = naming.name(record, editor.registry) {
                titles.insert(name, at: 0)
            } else {
                return ShapePath(head: .id(ancestor.description), rest: titles + [title])
            }
        }
        return ShapePath(head: .title(titles[0]), rest: Array(titles.dropFirst()) + [title])
    }

    /// The path of a shape: see `FileNames.path(of:)`.
    static func path(of id: ShapeID, in editor: CanvasEditor, naming: DrawNaming) -> ShapePath? {
        guard let record = editor.file.record(id), let title = naming.name(record, editor.registry) else { return nil }
        return path(inside: containers(above: id, in: editor), titled: title, in: editor, naming: naming)
    }

    /// The titles folded, as the plugin that names shapes folds one; nil for a blank title.
    static func folded(_ path: ShapePath, naming: DrawNaming) -> ShapePath? {
        let rest = path.rest.compactMap(naming.fold)
        guard rest.count == path.rest.count else { return nil }
        switch path.head {
        case .title(let title):
            return naming.fold(title).map { ShapePath(head: .title($0), rest: rest) }
        case .id(let text):
            return ShapePath(head: .id(UUID(uuidString: text)?.uuidString ?? text), rest: rest)
        case .board:
            return ShapePath(head: .board, rest: rest)
        }
    }

    /// A path with its titles folded, or why it can't be.
    func folded(_ path: ShapePath, _ statement: Statement) throws(DrawError) -> ShapePath {
        guard let naming else {
            throw DrawError(statement, .noNames, "paths name shapes, and nothing here gives shapes names",
                            hint: "leave paths out: without a plugin that names shapes, no shape can be named or found by name")
        }
        guard let folded = Self.folded(path, naming: naming) else {
            throw DrawError(statement, .syntax, "a title can't be blank", hint: "leave it out for an untitled shape")
        }
        return folded
    }

    /// How a message names a shape whose title the script has used for more than one: the path of a restated shape, or of a new one
    /// in the container it goes in (`board > "Title"` in no container on the root); its title in quotes when that is its alone.
    func said(_ item: ShapeItem) -> String? {
        guard let title = item.title else { return nil }
        guard isShared(title) else { return quoted(title) }
        return (path(of: item) ?? ShapePath(head: .board, rest: [title])).written
    }

    /// Whether more than one shape on the board the run draws on, or that the script makes, has this title.
    func isShared(_ title: String) -> Bool {
        let drawn = (itemsByTitle[title] ?? []).filter { items[$0].existing == nil }.count
        return (names.ids[title] ?? []).filter { !deletedShapes.contains($0) }.count + drawn > 1
    }

    /// The path of a shape the script restates, or makes.
    func path(of item: ShapeItem) -> ShapePath? {
        guard let naming, let title = item.title else { return nil }
        if let existing = item.existing { return Self.path(of: existing.id, in: editor, naming: naming) }
        var chain: [ShapeID]
        if let holder = item.holderID {
            chain = [holder] + Self.containers(above: holder, in: editor)
        } else if let owner = target.board.owner {
            chain = [owner] + Self.containers(above: owner, in: editor)
        } else {
            chain = []
        }
        return Self.path(inside: chain, titled: title, in: editor, naming: naming)
    }

    /// A board shape as a message names it when its title is not its alone: its path, and, in no container on the board the run
    /// draws on, `board > "Title"`. Nil when it has no title, or its title is its alone.
    func sharedName(of record: AnyShapeRecord) -> String? {
        guard let title = Drawing.title(of: record, names: names, naming: naming, registry: registry), isShared(title), let naming else { return nil }
        return (Self.path(of: record.id, in: editor, naming: naming) ?? ShapePath(head: .board, rest: [title])).written
    }

    /// A board shape's title for a message, in quotes, or its path when the title is not its alone; nil with no title.
    func said(titleOf record: AnyShapeRecord) -> String? {
        guard let title = Drawing.title(of: record, names: names, naming: naming, registry: registry) else { return nil }
        return sharedName(of: record) ?? quoted(title)
    }

    /// The kind of a candidate and its path, for a message that lists the shapes a name could mean.
    private func candidate(_ found: ShapeItem.Found) -> (said: String, at: String?)? {
        switch found {
        case .item(let index):
            let item = items[index]
            if let existing = item.existing { return fileNames?.candidate((existing.id, target.board)) }
            let said = item.pathKey?.written ?? path(of: item)?.written ?? item.title.map(quoted) ?? "on line \(item.statement.line)"
            return ("\(indefinite(item.kind)) \(said)", nil)
        case .shape(let record):
            return fileNames?.candidate((record.id, target.board))
        case .board, .view, .origin:
            return nil
        }
    }

    /// `ambiguous_title`, for a name that more than one shape of the board or the script has: each listed with its kind and its path,
    /// and the hint says to write the path or the id.
    func ambiguous(_ said: String, _ candidates: [ShapeItem.Found], _ statement: Statement) -> DrawError {
        // The path of the first that has one is the example the hint gives; a shape the script makes has no id to write yet.
        let example: ShapePath? = candidates.lazy.compactMap { found -> ShapePath? in
            switch found {
            case .shape(let record): return self.naming.flatMap { Self.path(of: record.id, in: self.editor, naming: $0) }
            case .item(let index): return self.items[index].pathKey ?? self.path(of: self.items[index])
            case .board, .view, .origin: return nil
            }
        }.first
        let madeHere = candidates.allSatisfy { if case .item(let index) = $0 { items[index].existing == nil } else { false } }
        let hint = example.map { "write the path of the one you mean, as \($0.written)" + (madeHere ? "" : ", or its #id, which a query's row gives") }
            ?? "write the #id of the one you mean, which a query's row gives"
        return DrawError(statement, .ambiguousTitle, "the board has \(candidates.count) shapes called \(said): \(FileNames.listing(candidates.compactMap(candidate)))", hint: hint)
    }

    // MARK: Finding the shapes a path names

    /// What a path leads to on the board the run draws on and elsewhere in the file, but for what the script deletes.
    struct PathResolution {
        /// The path, folded.
        var path: ShapePath
        var match: FileNames.PathMatch
        /// The shapes it names on the board the run draws on.
        var here: [FileNames.Place]
        /// The shapes it names on other boards the app can show.
        var elsewhere: [FileNames.Place]
        /// The holders the path less its last part leads to whose contents are on the board the run draws on: where a shape it
        /// names would be made.
        var holders: [FileNames.Container]
        /// The holders it leads to on other boards.
        var holdersElsewhere: [FileNames.Container]
        /// Whether the script deletes what it leads to, and nothing else is left.
        var deleted: Bool
    }

    /// What the file has for a path: see `PathResolution`.
    func resolve(_ path: ShapePath, _ statement: Statement) throws(DrawError) -> PathResolution {
        guard let fileNames else {
            throw DrawError(statement, .noNames, "paths name shapes, and nothing here gives shapes names",
                            hint: "leave paths out: without a plugin that names shapes, no shape can be named or found by name")
        }
        let match = fileNames.match(path, board: target.board)
        let taken = deletedShapes.isEmpty ? [] : takenBoards.boards(owned: deletedShapes, in: editor.file)
        func live(_ place: FileNames.Place) -> Bool { !deletedShapes.contains(place.id) && !taken.contains(place.board) }
        func live(_ holder: FileNames.Container) -> Bool {
            switch holder {
            case .board(let board): !taken.contains(board)
            case .shape(let id, on: let board): !deletedShapes.contains(id) && !taken.contains(board)
            case .none, .holdsNone, .ambiguous: false
            }
        }
        let shapes = match.shapes.filter(live), holders = match.holders.filter(live)
        return PathResolution(path: path, match: match, here: shapes.filter { $0.board == target.board },
                              elsewhere: shapes.filter { $0.board != target.board },
                              holders: holders.filter { $0.board == target.board }, holdersElsewhere: holders.filter { $0.board != target.board },
                              deleted: shapes.count < match.shapes.count && shapes.isEmpty)
    }

    /// The shapes of the board or the script a path names: a restated shape is its item, and a new one the script makes in the
    /// path's container is too.
    func found(_ resolution: PathResolution) -> [ShapeItem.Found] {
        var found: [ShapeItem.Found] = []
        for place in resolution.here {
            if let index = itemByID[place.id] {
                found.append(.item(index))
            } else if let record = target.document[place.id] {
                found.append(.shape(record))
            }
        }
        for index in itemsByTitle[resolution.path.last] ?? [] where items[index].existing == nil {
            if resolution.holders.contains(where: { $0.shapeID == items[index].holderID }) { found.append(.item(index)) }
        }
        return found
    }

    /// A shape a path names, among the script's and the board's; nil if one a statement that couldn't be resolved names. Why it
    /// is none: the script deletes it, it is on another board (`several_boards`, as a placement's target elsewhere is), or nothing
    /// is called that.
    func find(path written: ShapePath, _ statement: Statement, for what: String) throws(DrawError) -> ShapeItem.Found? {
        let path = try folded(written, statement)
        if unresolvedPaths.contains(path) { return nil }
        let resolution = try resolve(path, statement)
        let candidates = found(resolution)
        if candidates.count == 1 { return candidates[0] }
        if candidates.count > 1 { throw ambiguous(path.written, candidates, statement) }
        throw pathNotFound(resolution, statement, for: what, elsewhere: true)
    }

    /// Why a path names no shape of the board or the script.
    func pathNotFound(_ resolution: PathResolution, _ statement: Statement, for what: String, elsewhere: Bool, suffix: String = "") -> DrawError {
        let said = resolution.path.written
        if resolution.deleted {
            return DrawError(statement, .unknownTitle, "\(what) \(said), which this script deletes",
                             hint: "draw it again after deleting it, or leave it out")
        }
        if elsewhere, let place = resolution.elsewhere.first {
            return severalBoards(said: said, on: place.board, statement, for: what)
        }
        let path = resolution.path, match = resolution.match
        var hint: String
        switch match.stoppedAt {
        case nil:
            hint = "a path is one the board has as the script starts, or one the script draws"
        case 0?:
            hint = "a path starts with the frame or subboard its shapes are in, and none is called \(path.head.written)"
        case let stopped?:
            let part = path.rest[stopped - 1]
            var before = stopped == 1 ? path.head.written : quoted(path.rest[stopped - 2])
            // `board` is the top of the board the run draws on: said, where that is not the one the window shows.
            if stopped == 1, path.head == .board, target.board != editor.board {
                before = "board (the top of \(FileNames.named(target.board, in: editor, naming: naming)), where this run draws)"
            }
            let names = match.reached.flatMap { fileNames?.contents(of: $0) ?? [] }.compactMap { fileNames?.name(of: $0) }
            let guesses = Suggestions.closest(to: part, among: names)
            hint = guesses.isEmpty ? "\(before) holds no shape called \(quoted(part))" : "did you mean \(listed(guesses.map(quoted), or: true))?"
        }
        return DrawError(statement, .unknownTitle, "there's no shape called \(said)\(suffix)", hint: hint)
    }

    /// What an edge's end names by a path: the item of a shape the script restates or makes, a shape of the board, or one
    /// elsewhere in the file (the edge then goes through a stand-in beside the other end); a measure reads the shapes it draws alone.
    func endFound(path written: ShapePath, _ statement: Statement, written edge: String) throws(DrawError) -> (found: EdgeEndFound, name: EndName) {
        let path = try folded(written, statement)
        if unresolvedPaths.contains(path) { throw skip() }
        let name = EndName(title: path.last, path: path.written)
        if measuring {
            if let index = (itemsByTitle[path.last] ?? []).first(where: { items[$0].pathKey == path }) {
                return (.here(items[index].record.id, item: index), name)
            }
            throw measuredPathNotFound(path, statement)
        }
        let resolution = try resolve(path, statement)
        let candidates = found(resolution)
        if candidates.count > 1 { throw ambiguous(path.written, candidates, statement) }
        switch candidates.first {
        case .item(let index)?:
            return (.here(items[index].record.id, item: index), name)
        case .shape(let record)?:
            return (.here(record.id, item: nil), name)
        case .board?, .view?, .origin?:
            throw DrawError(statement, .internal, "\(path.written) names a place, not a shape")
        case nil:
            break
        }
        if resolution.elsewhere.count > 1 {
            let several = resolution.elsewhere
            throw DrawError(statement, .ambiguousTitle, "\(path.written) is on \(Set(several.map(\.board)).count) boards: \(fileNames?.listing(several) ?? "")",
                            hint: fileNames?.pathHint(for: several) ?? "write the #id of the one you mean, which a query's row gives")
        }
        if let place = resolution.elsewhere.first, let record = editor.file.record(place.id) {
            return (.away(FarShape(record: record, board: place.board)), name)
        }
        throw pathNotFound(resolution, statement, for: "\(edge) is drawn to", elsewhere: false)
    }

    /// A path in a measure that names no shape the script draws: the measure goes on without the edge.
    private func measuredPathNotFound(_ path: ShapePath, _ statement: Statement) -> DrawError {
        var missing = DrawError(statement, .unknownTitle, "there's no shape called \(path.written)")
        missing.fromNameLookup = true
        return missing
    }

    // MARK: Where a shape a path names goes

    /// Where a shape statement named by a path, or an `in`, is made: the holder, a frame's id (nil for the top of the board).
    /// For a path: restated if the path names a shape on the board, else made in the one holder the path leads to, which must be
    /// on the board and not one the script draws.
    struct Placing {
        /// The shape on the board it restates, if any.
        var existing: AnyShapeRecord?
        /// The frame it goes in (nil: the top of the board).
        var holder: ShapeID?
    }

    /// Resolves a shape statement's path: the shape it restates, or the container it is made in.
    func place(path written: ShapePath, word: String, _ statement: Statement) throws(DrawError) -> Placing {
        let path = try folded(written, statement)
        let resolution = try resolve(path, statement)
        let named = resolution.here.compactMap { target.document[$0.id] }
        if named.count > 1 {
            throw ambiguous(path.written, named.map(ShapeItem.Found.shape), statement)
        }
        if let existing = named.first { return Placing(existing: existing, holder: holderID(of: existing)) }
        // Made in the container the path leads to.
        if let place = resolution.elsewhere.first {
            throw severalBoards(said: path.written, on: place.board, statement, for: "\(word) restates")
        }
        if resolution.holders.count > 1 {
            let each = resolution.holders.compactMap { holder -> FileNames.Place? in
                switch holder {
                case .shape(let id, on: let board): (id, board)
                case .board(let board): board.owner.map { ($0, editor.file.board(containing: $0) ?? .root) }
                case .none, .holdsNone, .ambiguous: nil
                }
            }
            throw DrawError(statement, .ambiguousTitle,
                            "\(resolution.holders.count) places are called \(path.container?.written ?? path.head.written), and \(path.written) would be made in each: \(fileNames?.listing(each) ?? "")",
                            hint: "write a longer path, or the #id of the one you mean, which a query's row gives")
        }
        if let holder = resolution.holders.first { return Placing(existing: nil, holder: holder.shapeID) }
        // Nothing to be in: a container the script draws holds nothing yet; else the path's container is missing.
        let container = path.container
        if let container, drawsContainer(container) {
            throw DrawError(statement, .unsupported, "\(container.written) is drawn by this script, and a shape goes in one already on the board",
                            hint: "draw \(container.written) first, then run the shapes in it as a script of their own")
        }
        let match = resolution.match
        if match.stoppedAt == nil || match.stoppedAt == path.rest.count {
            // The container is there, on another board or deleted by this script.
            if let place = resolution.holdersElsewhere.first?.board {
                throw severalBoards(said: path.written, on: place, statement, for: "a shape is made at")
            }
            if match.holders.isEmpty == false {
                throw DrawError(statement, .unknownTitle, "\(container?.written ?? path.head.written) is deleted by this script, so nothing goes in it",
                                hint: "draw it again after deleting it, or leave this out")
            }
        }
        var hint = "a path starts with the frame or subboard a shape is in, and each part after it is inside the one before"
        if let stopped = match.stoppedAt, stopped == 0 { hint = "no frame or subboard is called \(path.head.written): a shape is made in a container the board has" }
        throw DrawError(statement, .unknownTitle, "there's no shape called \(container?.written ?? path.head.written) to be in", hint: hint)
    }

    /// Whether a script statement draws a shape of this name (a path's container, which a shape can't be made in yet).
    private func drawsContainer(_ name: ShapeName) -> Bool {
        switch name {
        case .title(let written):
            guard let title = fold(written) else { return false }
            return itemsByTitle[title]?.contains { items[$0].existing == nil } == true && !isOnBoard(title)
        case .path(let path):
            guard let naming, let folded = Self.folded(path, naming: naming) else { return false }
            return itemsByTitle[folded.last]?.contains { items[$0].existing == nil && items[$0].pathKey == folded } == true
        case .id:
            return false
        }
    }

    /// The frame a board shape is directly in, nil if it is on the board directly.
    func holderID(of record: AnyShapeRecord) -> ShapeID? {
        target.document.container(of: record.id, containingKinds: registry.containingKinds)
    }

    // MARK: Inside a container

    /// The frame a name holds, when it is a frame on the board the run draws on: what `in "F"` finds a shape's title inside of. Nil
    /// for a name that holds no frame (a subboard's board is the board the run draws on), or can't be told yet; `contain` says why.
    func frame(named name: ShapeName) -> ShapeID? {
        guard let fileNames else { return nil }
        let found: FileNames.Container
        switch name {
        case .title(let written):
            guard let title = fold(written) else { return nil }
            found = fileNames.container(called: title)
        case .id(let text):
            guard let uuid = UUID(uuidString: text) else { return nil }
            found = fileNames.container(withID: ShapeID(uuid))
        case .path(let path):
            guard let naming, let folded = Self.folded(path, naming: naming) else { return nil }
            found = fileNames.container(path: folded, board: target.board)
        }
        guard case .shape(let id, on: let board) = found, board == target.board else { return nil }
        return id
    }

    /// The board shapes called `title` that are in `frame`, at any depth.
    func boardShapes(called title: String, inside frame: ShapeID) -> [ShapeID] {
        let kinds = registry.containingKinds
        return boardShapes(called: title).filter { target.document.containers(of: $0, containingKinds: kinds).contains(frame) }
    }

    /// The board shapes called `title` that are in no container.
    func looseBoardShapes(called title: String) -> [ShapeID] {
        let kinds = registry.containingKinds
        return boardShapes(called: title).filter { target.document.container(of: $0, containingKinds: kinds) == nil }
    }

    /// The shape a lone title names inside a frame, among those the script draws and the board has: nil if none is. A restated
    /// shape counts by the shape it restates, one the script makes by the frame it goes in.
    func found(_ title: String, inside frame: ShapeID, _ statement: Statement) throws(DrawError) -> ShapeItem.Found? {
        let kinds = registry.containingKinds
        func isInside(_ holder: ShapeID?) -> Bool {
            guard let holder else { return false }
            return holder == frame || target.document.containers(of: holder, containingKinds: kinds).contains(frame)
        }
        var found: [ShapeItem.Found] = []
        var restated: Set<ShapeID> = []
        for index in itemsByTitle[title] ?? [] {
            let item = items[index]
            if let existing = item.existing {
                restated.insert(existing.id)
                if target.document.containers(of: existing.id, containingKinds: kinds).contains(frame) { found.append(.item(index)) }
            } else if isInside(item.holderID) {
                found.append(.item(index))
            }
        }
        for id in boardShapes(called: title, inside: frame) where !restated.contains(id) {
            if let record = target.document[id] { found.append(.shape(record)) }
        }
        if found.count > 1 { throw ambiguous(quoted(title), found, statement) }
        return found.first
    }
}
