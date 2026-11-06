import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import Foundation
import Topology

// `canvas apply`: a whole document drawn by key, on every board it reaches, in one step, or not at all. The document is drawn
// on a rehearsal of the editor (`editor.rehearsal()`), in `draw`'s own runs, a board at a time and in the order only the
// app knows: what holds shapes before what it holds, every shape before any property is written, a property naming a type
// after the type has its schema (a run that refuses a name not yet written is put off to a later round, so types come
// before their notes whatever board each is on), every shape and property before the edges, and a pill's shape stood for as
// it is (one a pill can't stand for until a person changes it, a private one, is refused, never changed); a pill an edge drew
// before is put where the document says now, and an
// edge drawn otherwise than the document draws it now (straight, or through a pill) is drawn anew. Each shape is named by its id, the drawing's from its record for a key
// it has, a new one picked here for any other (`DrawOptions.reserved`), placed exactly where the document says
// (`DrawOptions.places`), and a value may name a node by its key (`DrawOptions.keys`). What the drawing made whose key is gone
// is deleted. Then the editor takes in what the rehearsal did as one step (`editor.adopt`), and the drawing's record with it,
// so nothing reaches the file unless all of it lands. A refusal anywhere is the app's own words, naming the node's key or the
// edge's place in the list, and leaves the file as it was.

/// Draws `text`, a document with places, as one step on `editor`'s file (or, `dryRun`, says what it would do): the drawing it
/// names updated by key, its new keys' shapes made, its shapes whose keys are gone deleted; its top on the board of the shape
/// `on` names (a title, a path or an id, as a script writes a name: a subboard), else where the drawing was drawn, else the
/// root. `program` is what hints call the command line.
@MainActor
public func apply(document text: String, dryRun: Bool, on target: String?, program: String, in editor: CanvasEditor) throws(DocumentError) -> DocumentResult {
    let document = try DrawDocument(parsing: text, registry: editor.registry)
    guard let records = editor.registry.drawRecording else {
        throw DocumentError(reason: "no_drawings", message: "nothing here keeps drawings, so a document can't be drawn by key",
                            hint: "\(program) draw draws a script by titles")
    }
    guard let name = document.drawing else {
        throw DocumentError(reason: "invalid_document", message: "the document says no drawing",
                            hint: "write \"drawing\": \"<name>\": a later apply of the same name finds its shapes by their keys")
    }
    var run = DocumentRun(document: document, name: name, records: records, program: program, editor: editor)
    try run.prepare(on: target)
    return try run.draw(dryRun: dryRun)
}

/// A key a record keeps for a document's edge (its own key, else its ends and what tells it apart from another of the pair),
/// and for the pill an edge made.
enum RecordKey {
    static func edge(_ key: String) -> String { "edge " + key }
    static func pill(_ key: String) -> String { "pill " + key }
    /// The key a `canvas draw --drawing` run gives a shape it joins to a drawing that has none for it: its id, as a script writes one.
    static func joined(_ id: ShapeID) -> String { "\(ShapeName.idMark)\(id)" }
    static func isJoined(_ key: String, _ id: ShapeID) -> Bool { key == joined(id) }
}

@MainActor
struct DocumentRun {
    let document: DrawDocument
    let name: String
    let records: DrawRecording
    let program: String
    let editor: CanvasEditor
    let registry: Registry
    /// The drawing as the file has it.
    let before: DrawingRecord?

    /// The board the document's top goes on.
    private(set) var top: BoardID = .root
    /// Each node's id, by key: the drawing's for a key it made (on the board the node goes on), else a new one.
    private(set) var ids: [String: ShapeID] = [:]
    /// The ids new to the file.
    private(set) var made: Set<ShapeID> = []
    /// The board each node goes on, and how deep in frames on it.
    private(set) var boardOf: [String: BoardID] = [:]
    private(set) var depthOf: [String: Int] = [:]
    /// What the drawing made whose key is gone, or that is drawn anew (on another board, or of another kind).
    private(set) var deletes: [(key: String, id: ShapeID)] = []
    /// Each edge's key in the record.
    private(set) var edgeKeys: [String] = []

    /// What each run's lines are about, and what they did.
    private var nodeRows: [String: [DrawChange]] = [:]
    private var edgeRows: [Int: DrawChange] = [:]
    private var problems: [String: [JSONValue]] = [:]
    /// What the runs said, each with the shape whose issue it is: the drawing's own shapes' issues are said once, at the end.
    private var warnings: [(about: ShapeID?, said: DocumentResult.Warning)] = []
    private var warned: Set<String> = []
    /// The edges whose pill was put where the document says now.
    private var movedPills: Set<Int> = []

    init(document: DrawDocument, name: String, records: DrawRecording, program: String, editor: CanvasEditor) {
        self.document = document
        self.name = name
        self.records = records
        self.program = program
        self.editor = editor
        registry = editor.registry
        before = records.read(name, editor.file)
    }

    // MARK: Where everything goes

    mutating func prepare(on target: String?) throws(DocumentError) {
        let file = editor.file
        let recorded = before.flatMap { BoardID(recorded: $0.board) }
        if let target {
            top = try board(named: target)
            if let recorded, recorded != top, before?.shapes.keys.contains(where: { UUID(uuidString: $0).map { file.record(ShapeID($0)) != nil } ?? false }) == true {
                throw DocumentError(reason: "several_boards", message: "\(quoted(name)) is drawn on another board than --on names",
                                    hint: "leave --on out to draw it where it is, or draw it as another drawing")
            }
        } else if let recorded, editor.canShow(recorded) {
            top = recorded
        }
        guard editor.canShow(top) else {
            throw DocumentError(reason: "board_gone", message: "the board \(quoted(name)) was drawn on is gone", hint: "say where with --on")
        }
        let known = before?.idsByKey ?? [:]
        // Each key the drawing has keeps its shape where it can: the same kind, on the board the node goes on. A shape the
        // node can't be (another kind, another board: `draw` moves no shape between boards) is deleted and drawn anew.
        for node in document.nodes {
            if let id = known[node.key], let record = file.record(id) {
                if record.kind == node.kind {
                    ids[node.key] = id
                    continue
                }
                deletes.append((node.key, id))
            }
            mint(node.key)
        }
        var settled = false
        while !settled {
            settled = true
            boardOf = [:]
            depthOf = [:]
            for node in document.nodes { _ = place(node.key) }
            for node in document.nodes {
                guard let id = ids[node.key], !made.contains(id), let on = file.board(containing: id), on != boardOf[node.key] else { continue }
                deletes.append((node.key, id))
                mint(node.key)
                settled = false
            }
        }
        // What the drawing made whose key is gone.
        let wanted = Set(document.nodes.map(\.key))
        edgeKeys = try edgeRecordKeys()
        let edgeWanted = Set(edgeKeys.flatMap { [RecordKey.edge($0), RecordKey.pill($0)] })
        for (text, shape) in (before?.shapes ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let uuid = UUID(uuidString: text), file.record(ShapeID(uuid)) != nil else { continue }
            // What a `canvas draw --drawing` run joined to the drawing (keyed by its own id) is no document's to delete.
            if RecordKey.isJoined(shape.key, ShapeID(uuid)) { continue }
            if !wanted.contains(shape.key), !edgeWanted.contains(shape.key) { deletes.append((shape.key, ShapeID(uuid))) }
        }
        // An edge the drawing drew otherwise than the document draws it now is drawn anew: straight where it goes through a pill
        // now, through one where it is straight now, or from another board. `draw` keeps an edge as it was drawn (an arrow
        // through a pill is the edge, and `via:` over one drawn straight is refused), so its arrow goes first.
        // A node drawn anew (another board, another kind) is another shape: an arrow at it went with the old one, and one into a pill
        // that stood for it would stay, standing for nothing the drawing has.
        let anew = Set(document.nodes.compactMap { node in known[node.key].map { $0 != ids[node.key] } == true ? node.key : nil })
        var contexts: [BoardID: ShapeContext] = [:]
        // The edges through pills come in groups, one a pill: the edge that makes it (no share) and those that share it, by its
        // near end (the host) and the end it stands for. Which edge of a group the plan calls its maker is the plan's to pick, so
        // a group keeps the pill its arrows already share whichever it picks; an arrow in another group's pill (a group the
        // plan split, or a sharer that shares another host now) is drawn anew, and so is a group whose maker's arrow isn't
        // through a pill it may keep.
        func ends(_ edge: DrawDocument.Edge) -> (near: String, far: String)? {
            guard let pill = edge.pill else { return nil }
            let far = pill.standsFor ?? edge.to
            return (far == edge.to ? edge.from : edge.to, far)
        }
        var maker: [String: Int] = [:]
        for edge in document.edges {
            guard edge.pill?.share == nil, let (near, far) = ends(edge) else { continue }
            if maker[near + "\u{0}" + far] == nil { maker[near + "\u{0}" + far] = edge.index }
        }
        var groupOf: [Int: Int] = [:], pillOf: [Int: ShapeID] = [:], straight: [Int: Bool] = [:], arrows: [Int: ShapeID] = [:]
        for edge in document.edges {
            let recordKey = RecordKey.edge(edgeKeys[edge.index])
            if let (near, far) = ends(edge), let group = maker[(edge.pill?.share ?? near) + "\u{0}" + far] { groupOf[edge.index] = group }
            guard let arrow = known[recordKey], let record = file.record(arrow), let on = file.board(containing: arrow),
                  let from = ids[edge.from], let to = ids[edge.to] else { continue }
            arrows[edge.index] = arrow
            // a node drawn anew (another board, another kind) is another shape: an arrow at it went with the old one, and one into
            // a pill that stood for it would stay, standing for nothing the drawing has
            if anew.contains(edge.from) || anew.contains(edge.to) { continue }
            if contexts[on] == nil { contexts[on] = ShapeContext(document: file[on], registry: registry) }
            let bound = Set(record.boundShapes(in: contexts[on]!))
            guard let (near, far) = ends(edge) else {
                straight[edge.index] = on == boardOf[edge.from] && bound.contains(from) && bound.contains(to)
                continue
            }
            // through a pill: from the near end, not to the far one, on the near end's board, into one other shape
            guard let nearID = ids[near], let farID = ids[far], on == boardOf[near], bound.contains(nearID), !bound.contains(farID),
                  bound.count == 2, let pill = bound.subtracting([nearID]).first else { continue }
            pillOf[edge.index] = pill
        }
        // Whose each pill is: the group of the edge the record keeps it under, where that group still runs into it; else the
        // first group whose maker's arrow does; else the first that does.
        var pillKeyEdge: [String: Int] = [:]
        for edge in document.edges { pillKeyEdge[RecordKey.pill(edgeKeys[edge.index])] = edge.index }
        var recordedUnder: [ShapeID: Int] = [:]
        for (text, shape) in before?.shapes ?? [:] {
            if let uuid = UUID(uuidString: text), let edge = pillKeyEdge[shape.key] { recordedUnder[ShapeID(uuid)] = edge }
        }
        var users: [ShapeID: Set<Int>] = [:]
        for (edge, pill) in pillOf { if let group = groupOf[edge] { users[pill, default: []].insert(group) } }
        var ownerOf: [ShapeID: Int] = [:]
        for (pill, groups) in users {
            if let edge = recordedUnder[pill], let group = groupOf[edge], groups.contains(group) {
                ownerOf[pill] = group
            } else {
                ownerOf[pill] = groups.sorted().first { pillOf[$0] == pill } ?? groups.min()
            }
        }
        // The pill each group keeps: its maker's, where its maker's arrow runs into a pill the group owns.
        var kept: [Int: ShapeID] = [:]
        for group in Set(groupOf.values) { if let pill = pillOf[group], ownerOf[pill] == group { kept[group] = pill } }
        for edge in document.edges {
            guard let arrow = arrows[edge.index] else { continue }
            let asPlanned = edge.pill == nil
                ? straight[edge.index] == true
                : pillOf[edge.index] != nil && groupOf[edge.index].flatMap { kept[$0] } == pillOf[edge.index]
            if !asPlanned { deletes.append((RecordKey.edge(edgeKeys[edge.index]), arrow)) }
        }
        // A shape deleted takes its board with it: never one holding what the drawing didn't make.
        let drawn = Set((before?.shapes ?? [:]).keys.compactMap { UUID(uuidString: $0).map(ShapeID.init) }).union(ids.values)
        for (key, id) in deletes {
            for board in file.subtree(ownedBy: [id]) {
                guard let stranger = file[board].shapes.first(where: { !drawn.contains($0.id) }) else { continue }
                if document.node(key) != nil {
                    throw DocumentError(key: key, reason: ScriptError.Reason.readOnly.rawValue,
                                        message: "\(quoted(key)) is drawn anew (it goes on another board now, or is another kind), and the board of the shape it was holds \(indefinite(stranger.kind)) the drawing didn't make",
                                        hint: "move what is yours off that board first, or keep the node where it was")
                }
                throw DocumentError(key: key, reason: ScriptError.Reason.readOnly.rawValue,
                                    message: "\(quoted(key)) is gone from the document, and its board holds \(indefinite(stranger.kind)) the drawing didn't make",
                                    hint: "move what is yours off its board first, or keep the key")
            }
        }
    }

    private mutating func mint(_ key: String) {
        let id = ShapeID()
        ids[key] = id
        made.insert(id)
    }

    /// The board a node goes on, and how deep in frames, found once.
    private mutating func place(_ key: String) -> BoardID {
        if let board = boardOf[key] { return board }
        guard let node = document.node(key) else { return top }
        var board = top, depth = 0
        if let container = node.container, let holder = document.node(container) {
            if registry.boardOwningKinds.contains(holder.kind), let owner = ids[container] {
                board = BoardID(owner: owner)
            } else {
                board = place(container)
                depth = (depthOf[container] ?? 0) + 1
            }
        }
        boardOf[key] = board
        depthOf[key] = depth
        return board
    }

    /// The board the shape `written` names holds: a subboard's, by its title, a path or an id.
    private func board(named written: String) throws(DocumentError) -> BoardID {
        try Self.board(named: written, in: editor, program: program)
    }

    /// The board the shape `written` names holds, in `editor`'s file: `--on`'s, for apply and for a measure of a document.
    static func board(named written: String, in editor: CanvasEditor, program: String) throws(DocumentError) -> BoardID {
        let registry = editor.registry
        guard let naming = registry.drawNaming else {
            throw DocumentError(reason: ScriptError.Reason.noNames.rawValue, message: "nothing here gives shapes names, so --on can't find one")
        }
        let names = FileNames(editor, naming: naming)
        var name = ShapeName.title(written)
        if ShapeName.isScriptSpelling(written), let parsed = try? ShapeName(parsing: written) { name = parsed }
        switch names.container(named: name, boards: true, board: editor.board) {
        case .board(let board)?, .shape(_, on: let board)?:
            return board
        case .holdsNone(let record)?:
            throw DocumentError(reason: ScriptError.Reason.cannotContain.rawValue, message: "\(quoted(written)) is \(indefinite(record.kind)), which holds no board",
                                hint: "--on names a shape that holds a board (a subboard)")
        case .ambiguous(let boards, let listing, let hint)?:
            throw DocumentError(reason: ScriptError.Reason.ambiguousTitle.rawValue, message: "\(boards.count) shapes that hold boards are called \(quoted(written)): \(listing)", hint: hint)
        case nil, .none?:
            throw DocumentError(reason: ScriptError.Reason.unknownTitle.rawValue, message: "there's no shape called \(quoted(written)) that holds a board",
                                hint: "\(program) query 'subboard' lists the subboards")
        }
    }

    /// Each edge's key in the record: its own key, else its ends and the values of what tells two arrows of a pair apart (`is`),
    /// as written; a second edge alike gets its place in the list after it.
    /// Refused for two edges of one key (a key given twice, or one that is another edge's key worked out): the record keeps an
    /// arrow by its edge's key, so a later apply would find one arrow for both.
    private func edgeRecordKeys() throws(DocumentError) -> [String] {
        let identity = registry.drawEdgeIdentityKeys
        var seen: [String: Int] = [:]
        let keys = document.edges.map { edge in
            if let key = edge.key { return key }
            var key = "\(edge.from) -> \(edge.to)"
            for name in identity { if let value = edge.props[name], value != .null { key += " \(name) \(value.compactText)" } }
            seen[key, default: 0] += 1
            return seen[key]! > 1 ? "\(key) #\(seen[key]!)" : key
        }
        var first: [String: Int] = [:], refusals: [DocumentError.Refusal] = []
        for (place, key) in keys.enumerated() {
            guard let other = first[key] else {
                first[key] = place
                continue
            }
            let index = document.edges[place].index, otherIndex = document.edges[other].index
            refusals.append(DocumentError.Refusal(key: nil, edge: index, reason: ScriptError.Reason.duplicate.rawValue,
                                                  message: "edges[\(index)]'s key is \(quoted(key)), as edges[\(otherIndex)]'s is",
                                                  hint: "give each edge a key of its own, or none (an edge's ends and is: tell it apart)"))
        }
        guard refusals.isEmpty else { throw DocumentError(refusals) }
        return keys
    }

    // MARK: Drawing it

    mutating func draw(dryRun: Bool) throws(DocumentError) -> DocumentResult {
        let copy = editor.rehearsal()
        let current = Dictionary(uniqueKeysWithValues: ids.values.compactMap { id in DrawnState.of(id, in: editor.file, registry: registry).map { (id, $0) } })

        try deleteGone(on: copy)
        try drawShapes(on: copy)
        try writeProperties(on: copy)
        let kinds = try pillKinds(on: copy)
        let drawnEdges = try drawEdges(on: copy, standIns: kinds)
        placePills(on: copy)
        try audit(on: copy)
        sayIssues(on: copy)
        writeRecord(on: copy, edges: drawnEdges)

        if !dryRun, !editor.adopt(copy, named: DrawStyle.stepName) {
            throw DocumentError(reason: ScriptError.Reason.busy.rawValue, message: "the board changed while the document was drawn, so nothing was",
                                hint: "apply it again")
        }
        return verdicts(copy: copy, current: current, edges: drawnEdges, dryRun: dryRun)
    }

    /// One run of `draw` on the copy, on `board`, of `lines`; each line's subject (a node's key, an edge's place) in `about`.
    private mutating func run(_ lines: [String], about: [Subject], on board: BoardID, places: [Int: CGPoint] = [:], dryRun: Bool = false,
                              in copy: CanvasEditor) throws(DrawError) -> DrawResult {
        let options = DrawOptions(reserved: made, places: places, keys: ids, board: board, program: true)
        return try Draw.draw(script: lines.joined(separator: "\n"), dryRun: dryRun, reveal: false, program: program, options: options, in: copy)
    }

    enum Subject: Hashable {
        case node(String)
        case edge(Int)
    }

    /// The boards in the order a run can draw on them: the top, then each board whose holder is on a board drawn before it.
    private var boardOrder: [BoardID] {
        var order: [BoardID] = [top], seen: Set<BoardID> = [top]
        var changed = true
        while changed {
            changed = false
            for node in document.nodes where registry.boardOwningKinds.contains(node.kind) {
                guard let id = ids[node.key], seen.contains(boardOf[node.key] ?? top), !seen.contains(BoardID(owner: id)) else { continue }
                let board = BoardID(owner: id)
                guard document.nodes.contains(where: { boardOf[$0.key] == board }) else { continue }
                order.append(board)
                seen.insert(board)
                changed = true
            }
        }
        return order
    }

    private mutating func deleteGone(on copy: CanvasEditor) throws(DocumentError) {
        guard !deletes.isEmpty else { return }
        let file = copy.file
        var shapes: [BoardID: [(key: String, id: ShapeID)]] = [:], arrows: [BoardID: Set<ShapeID>] = [:]
        let edgeKind = registry.drawEdging.flatMap { $0.kind(registry) }
        // A shape on a board that a shape deleted takes with it (a subboard's, at any depth) goes with that one, and is no
        // delete of its own: whichever board's run came first, the other would find it gone.
        let taken = Set(file.subtree(ownedBy: deletes.map(\.id)))
        for (key, id) in deletes {
            guard let board = file.board(containing: id), !taken.contains(board), let record = file.record(id) else { continue }
            if record.kind == edgeKind || !registry.drawCanName(record) { arrows[board, default: []].insert(id) } else { shapes[board, default: []].append((key, id)) }
        }
        // Arrows and pills, by id, with the pills they leave with no arrow: a script names neither.
        let route = StandInRoute(registry)
        let mine = Set((before?.shapes ?? [:]).keys.compactMap { UUID(uuidString: $0).map(ShapeID.init) })
        for (board, gone) in arrows.sorted(by: { $0.key.description < $1.key.description }) {
            // The drawing's other arrows into a pill that goes (they shared it) go with it rather than lose an end: an edge still
            // wanted is drawn anew, as the document places it.
            var leaving = gone
            let context = ShapeContext(document: copy.file[board], registry: registry)
            copy.file[board].shapes.forEach { record in
                guard registry.referencingKinds.contains(record.kind), mine.contains(record.id), !gone.contains(record.id) else { return }
                if !gone.isDisjoint(with: record.boundShapes(in: context)) { leaving.insert(record.id) }
            }
            let emptied = route.map { Set($0.emptied(by: leaving, in: copy.file[board])).intersection(mine) } ?? []
            copy.transact(on: board, DrawStyle.stepName) { transaction in transaction.byAgent = true; transaction.delete(leaving.union(emptied)) }
        }
        for (board, gone) in shapes.sorted(by: { $0.key.description < $1.key.description }) {
            let lines = gone.map { "\(Keyword.delete.rawValue) \(ShapeName.idMark)\($0.id)" }
            do throws(DrawError) {
                _ = try run(lines, about: gone.map { .node($0.key) }, on: board, in: copy)
            } catch {
                throw refusal(error, about: gone.map { .node($0.key) })
            }
        }
    }

    /// A node's `size:` clause (its props' size, else its place's) and where its room's top-left goes on the copy as it is now
    /// (`place.at` from its frame's top-left, else its board's origin), if the document says.
    private func sizeAndPlace(of node: DrawDocument.Node, on copy: CanvasEditor) -> (size: String, at: CGPoint?) {
        var size = ""
        if let given = node.props[LanguageKey.size.rawValue] {
            size = " \(LanguageKey.size.rawValue): \(given.stringValue ?? given.compactText)"
        } else if let given = node.place?.size {
            size = " \(LanguageKey.size.rawValue): \(Drawing.written(given))"
        }
        guard let at = node.place?.at else { return (size, nil) }
        var origin = CGPoint.zero
        if let container = node.container, let holder = document.node(container), let holderID = ids[container],
           !registry.boardOwningKinds.contains(holder.kind), let box = copy.file.record(holderID)?.box { origin = box.origin }
        return (size, CGPoint(x: origin.x + at.x, y: origin.y + at.y))
    }

    /// Every node made or moved where it goes, board by board, what holds shapes before what it holds; no property yet.
    private mutating func drawShapes(on copy: CanvasEditor) throws(DocumentError) {
        for board in boardOrder {
            let here = document.nodes.filter { boardOf[$0.key] == board }
            guard !here.isEmpty else { continue }
            for depth in 0...(here.map { depthOf[$0.key] ?? 0 }.max() ?? 0) {
                var lines: [String] = [], about: [Subject] = [], places: [Int: CGPoint] = [:]
                for node in here where depthOf[node.key] == depth {
                    guard let id = ids[node.key] else { continue }
                    var line = "\(node.kind.rawValue) \(ShapeName.idMark)\(id)"
                    if let container = node.container, document.node(container) != nil, let holderID = ids[container] {
                        line += " in \(ShapeName.idMark)\(holderID)"
                    } else if let owner = top.owner {
                        line += " in \(ShapeName.idMark)\(owner)"
                    }
                    let (size, at) = sizeAndPlace(of: node, on: copy)
                    line += size
                    if let at { places[lines.count + 1] = at }
                    lines.append(line)
                    about.append(.node(node.key))
                }
                guard !lines.isEmpty else { continue }
                do throws(DrawError) {
                    let result = try run(lines, about: about, on: board, places: places, in: copy)
                    note(result, about: about)
                } catch {
                    throw refusal(error, about: about)
                }
            }
        }
    }

    /// Every node's properties, in one statement a node, a run a board; a run refused only for naming a node whose own
    /// properties aren't written yet (a type before its schema) is drawn again without those statements, which wait for a
    /// later round, so what a value names is written first, on whatever board. Each statement says its size and place again:
    /// what a node holds can lay it out otherwise than the shape it was made as (a type's instance has rows; a relationship type
    /// is a pill about the middle of the box it stores, which its words make taller), and the frame it is laid out in is the one
    /// the document places.
    private mutating func writeProperties(on copy: CanvasEditor) throws(DocumentError) {
        var pending: [BoardID: [DrawDocument.Node]] = [:]
        for node in document.nodes where !node.props.filter({ $0.key != LanguageKey.size.rawValue }).isEmpty {
            pending[boardOf[node.key] ?? top, default: []].append(node)
        }
        var waiting = Set(pending.values.joined().map(\.key))
        while !waiting.isEmpty {
            var progressed = false
            var last: (DrawError, [Subject])?
            for board in boardOrder {
                var nodes = (pending[board] ?? []).filter { waiting.contains($0.key) }
                while !nodes.isEmpty {
                    var lines: [String] = [], places: [Int: CGPoint] = [:]
                    for node in nodes {
                        let (size, at) = sizeAndPlace(of: node, on: copy)
                        if let at { places[lines.count + 1] = at }
                        lines.append(statement(writing: node) + size)
                    }
                    let about = nodes.map { Subject.node($0.key) }
                    do throws(DrawError) {
                        let result = try run(lines, about: about, on: board, places: places, in: copy)
                        note(result, about: about)
                        for node in nodes { waiting.remove(node.key) }
                        progressed = true
                        nodes = []
                    } catch {
                        // Put off what names a node still waiting; anything else is the document's to mend.
                        var later: Set<Int> = []
                        for each in error.errors.isEmpty ? [error] : error.errors {
                            guard let line = each.line, each.fromNameLookup, let key = each.lookedFor, waiting.contains(key) else {
                                throw refusal(error, about: about)
                            }
                            later.insert(line)
                        }
                        last = (error, about)
                        nodes = nodes.enumerated().filter { !later.contains($0.offset + 1) }.map(\.element)
                    }
                }
            }
            if !progressed, let last { throw refusal(last.0, about: last.1) }
            if !progressed { break }
        }
    }

    /// A node's statement of its properties: its title, then every other attribute as written (a text that a list or an object
    /// is given takes its JSON text).
    private func statement(writing node: DrawDocument.Node) -> String {
        var line = "\(node.kind.rawValue) \(ShapeName.idMark)\(ids[node.key]!)"
        let vocabulary = KindVocabulary(node.kind, in: registry)
        for (key, value) in node.props.sorted(by: { $0.key < $1.key }) where key != LanguageKey.size.rawValue {
            if key == LanguageKey.title.rawValue || key == vocabulary.namingProperty {
                guard let title = value.stringValue else { continue }
                line += " \(LanguageKey.title.rawValue): \(DrawDocument.quotedLiteral(title))"
                continue
            }
            line += " \(key): \(DrawDocument.literal(value, takesText: Self.takesText(key, vocabulary)))"
        }
        return line
    }

    private static func takesText(_ key: String, _ vocabulary: KindVocabulary) -> Bool {
        if case .string? = vocabulary.schema.shape(of: key) { return true }
        return false
    }

    /// The kind each edge's pill is: the first maker that stands for the pill's shape as the shape is. A shape no maker
    /// stands for until it's changed (a private one: a person made it so) is refused and left as it is, since making it
    /// what the pill needs (public) is the person's call, as for `canvas draw`; a kind no pill stands for is refused too.
    private func pillKinds(on copy: CanvasEditor) throws(DocumentError) -> [Int: ShapeKind] {
        let standIns = registry.standIns
        var kinds: [Int: ShapeKind] = [:]
        for edge in document.edges {
            guard let pill = edge.pill else { continue }
            let far = pill.standsFor ?? edge.to
            guard let id = ids[far], let record = copy.file.record(id) else { continue }
            if let chosen = standIns.makers.first(where: { standIns.admits($0, record) }) {
                kinds[edge.index] = chosen
                continue
            }
            // A maker that would stand for it once changed, asked of a copy and never written: what the shape lacks.
            let wanting = standIns.makers.first { maker in
                var probe = record
                return standIns.fulfil(maker, &probe)
            }
            if let wanting {
                // What the shape lacks is the person's to give it, said in the kind's word where it has one.
                let (lacks, ask) = standIns.needs(wanting).map { need in
                    ("which isn't \(need), and only \(indefinite(need)) shape can be stood for", "ask the user to make \(quoted(far)) \(need) (it's theirs to say)")
                } ?? ("which no pill stands for as it is", "ask the user whether \(quoted(far)) may be stood for (it's theirs to say)")
                throw DocumentError(key: far, edge: edge.index, reason: ScriptError.Reason.invalidValue.rawValue,
                                    message: "edges[\(edge.index)] goes through a pill for \(quoted(far)), \(lacks)", hint: "\(ask), or leave the edge out")
            }
            throw DocumentError(key: far, edge: edge.index, reason: ScriptError.Reason.invalidValue.rawValue,
                                message: "edges[\(edge.index)] goes through a pill for \(quoted(far)), \(indefinite(record.kind)), and no pill can stand for one",
                                hint: "canvas kinds says which kinds a pill can stand for (via); draw the edge straight")
        }
        return kinds
    }

    /// Every edge, a run a board: the pills edges make first, then those that share one, then the arrows drawn straight.
    private mutating func drawEdges(on copy: CanvasEditor, standIns kinds: [Int: ShapeKind]) throws(DocumentError) -> [Int: DrawChange] {
        var byBoard: [BoardID: [DrawDocument.Edge]] = [:]
        for edge in document.edges {
            let near = edge.pill.map { ($0.standsFor ?? edge.to) == edge.to ? edge.from : edge.to } ?? edge.from
            let board = boardOf[near] ?? top
            if edge.pill == nil, boardOf[edge.from] != boardOf[edge.to] {
                throw DocumentError(edge: edge.index, reason: ScriptError.Reason.severalBoards.rawValue,
                                    message: "edges[\(edge.index)] joins \(quoted(edge.from)) and \(quoted(edge.to)), which are on two boards",
                                    hint: "an edge between boards goes through a pill: give it place.pill")
            }
            byBoard[board, default: []].append(edge)
        }
        let rank: (DrawDocument.Edge) -> Int = { edge in edge.pill == nil ? 2 : edge.pill?.share != nil ? 1 : 0 }
        for board in boardOrder {
            let edges = (byBoard[board] ?? []).enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
            guard !edges.isEmpty else { continue }
            var lines: [String] = [], about: [Subject] = [], places: [Int: CGPoint] = [:]
            for edge in edges {
                guard let from = ids[edge.from], let to = ids[edge.to] else { continue }
                var line = "\(Keyword.edge.rawValue) \(ShapeName.idMark)\(from) -> \(ShapeName.idMark)\(to)"
                if let pill = edge.pill {
                    let far = pill.standsFor ?? edge.to
                    if far == edge.to, let kind = kinds[edge.index] {
                        line += " \(EdgeKey.via.rawValue): \(kind.rawValue)"
                    } else if boardOf[edge.from] == boardOf[edge.to] {
                        throw DocumentError(edge: edge.index, reason: ScriptError.Reason.invalidValue.rawValue,
                                            message: "edges[\(edge.index)]'s pill stands for its start, \(quoted(edge.from)), which is on the board the pill is on",
                                            hint: "a pill stands for an edge's start only when the start is on another board")
                    }
                    if let share = pill.share, share == edge.from || share == edge.to {
                        // Another edge of the same pair, into the pill its own end's first edge made. An edge that writes what tells
                        // a pair's edges apart (`is`) goes into the near end's own pill of itself (draw's host rule); `share: true`
                        // would take the first pill in the container for that end, whoever's it is.
                        let identified = registry.drawEdgeIdentityKeys.contains { edge.props[$0].map { $0 != .null } ?? false }
                        if !identified { line += " \(EdgeKey.share.rawValue): true" }
                    } else if let share = pill.share, let host = ids[share] {
                        line += " \(EdgeKey.share.rawValue): \(ShapeName.idMark)\(host)"
                    } else {
                        var origin = CGPoint.zero
                        if let container = pill.container, let holderID = ids[container] {
                            line += " in \(ShapeName.idMark)\(holderID)"
                            if let holder = document.node(container), !registry.boardOwningKinds.contains(holder.kind),
                               let box = copy.file.record(holderID)?.box { origin = box.origin }
                        }
                        if let at = pill.at { places[lines.count + 1] = CGPoint(x: origin.x + at.x, y: origin.y + at.y) }
                    }
                }
                let vocabulary = registry.drawEdging.flatMap { $0.kind(registry) }.map { KindVocabulary($0, in: registry) }
                for (key, value) in edge.props.sorted(by: { $0.key < $1.key }) {
                    line += " \(key): \(DrawDocument.literal(value, takesText: vocabulary.map { Self.takesText(key, $0) } ?? false))"
                }
                lines.append(line)
                about.append(.edge(edge.index))
            }
            do throws(DrawError) {
                let result = try run(lines, about: about, on: board, places: places, in: copy)
                note(result, about: about)
            } catch {
                throw refusal(error, about: about)
            }
        }
        return edgeRows
    }

    /// What each node still needs or has wrong, read from a dry run of every node as it is once all is drawn.
    private mutating func audit(on copy: CanvasEditor) throws(DocumentError) {
        for board in boardOrder {
            let here = document.nodes.filter { boardOf[$0.key] == board }
            guard !here.isEmpty else { continue }
            let lines = here.map { "\($0.kind.rawValue) \(ShapeName.idMark)\(ids[$0.key]!)" }
            guard let result = try? run(lines, about: here.map { .node($0.key) }, on: board, dryRun: true, in: copy) else { continue }
            for row in result.changes {
                guard row.line >= 1, row.line <= here.count, let found = row.problems, !found.isEmpty else { continue }
                problems[here[row.line - 1].key] = found.compactMap { try? JSONValue(encoding: $0) }
            }
        }
    }

    /// Each pill an edge drew before put where the document says now: in the frame `place.pill.in` names (or on its board), at
    /// `place.pill.at` from its top-left. A run that finds an edge drawn already places nothing, so a redraw whose cards moved would
    /// leave their pills where they were. A pill a run made now is there already, and moves nothing.
    private mutating func placePills(on copy: CanvasEditor) {
        var byBoard: [BoardID: [(edge: Int, pill: ShapeID, container: ShapeID?, origin: CGPoint)]] = [:], placed: Set<ShapeID> = []
        for edge in document.edges {
            guard let pill = edge.pill, pill.share == nil, let at = pill.at, let id = edgeRows[edge.index]?.standIn, !placed.contains(id),
                  let record = copy.file.record(id), let box = record.box, let board = copy.file.board(containing: id) else { continue }
            placed.insert(id)
            var container: ShapeID?, origin = CGPoint.zero
            if let key = pill.container, let holder = document.node(key), let holderID = ids[key], !registry.boardOwningKinds.contains(holder.kind) {
                container = holderID
                origin = copy.file.record(holderID)?.box?.origin ?? .zero
            }
            let place = CGPoint(x: origin.x + at.x, y: origin.y + at.y)
            guard record.container != container || box.origin != place else { continue }
            byBoard[board, default: []].append((edge.index, id, container, place))
        }
        for (board, moves) in byBoard.sorted(by: { $0.key.description < $1.key.description }) {
            copy.transact(on: board, DrawStyle.stepName) { transaction in
                transaction.byAgent = true
                for move in moves {
                    if transaction.document[move.pill]?.container != move.container { transaction.setContainer(move.pill, to: move.container) }
                    transaction.moveBox(move.pill, to: move.origin)
                }
            }
            for move in moves where copy.file.record(move.pill)?.box?.origin == move.origin { movedPills.insert(move.edge) }
        }
    }

    /// Every issue of the drawing's shapes as the copy leaves them, once: each node's, then each edge's arrow's and pill's, by
    /// key or edge. What a phase said of them mid-way is left out (a phase brings what a later one mends: a relationship's row
    /// empty until the edges are drawn), and so is what a shape still needs (a node's `problems` say it). What a run brought to
    /// a shape that isn't the drawing's is kept as it was said.
    private mutating func sayIssues(on copy: CanvasEditor) {
        var drawn: [ShapeID: (key: String?, edge: Int?)] = [:], order: [ShapeID] = []
        func own(_ id: ShapeID, key: String?, edge: Int?) {
            guard drawn[id] == nil else { return }
            drawn[id] = (key, edge)
            order.append(id)
        }
        for node in document.nodes { if let id = ids[node.key] { own(id, key: node.key, edge: nil) } }
        for edge in document.edges {
            guard let row = edgeRows[edge.index] else { continue }
            if let arrow = row.arrow { own(arrow, key: nil, edge: edge.index) }
            if let pill = row.standIn { own(pill, key: nil, edge: edge.index) }
        }
        warnings.removeAll { warning in warning.about.map { drawn[$0] != nil } ?? false }
        var contexts: [BoardID: ShapeContext] = [:]
        for id in order {
            guard let board = copy.file.board(containing: id), let owner = drawn[id] else { continue }
            let key = owner.key, edge = owner.edge
            if contexts[board] == nil { contexts[board] = copy.shapeContext.over(copy.contents(of: board)) }
            guard let shapes = contexts[board], let record = shapes.shape(id) else { continue }
            let found = registry.drawCheck.map { $0.check(record, shapes) }
                ?? registry.schemaViolations(of: record).map { DrawIssue($0.message, field: $0.property) }
            for issue in found where !issue.isIncomplete {
                let severity: DrawWarning.Severity = issue.isError ? .error : .warning
                let name = key.map(quoted) ?? "edges[\(edge ?? 0)]"
                warnings.append((id, DocumentResult.Warning(key: key, edge: edge, message: "\(name): \(keyed(issue.message))",
                                                            severity: severity.rawValue, attribute: issue.field)))
            }
        }
    }

    /// The drawing's record as the copy leaves it: every node's shape, every edge's arrow and the pill it made, each with what
    /// it is now.
    private func writeRecord(on copy: CanvasEditor, edges: [Int: DrawChange]) {
        var record = DrawingRecord(board: top.description)
        func keep(_ id: ShapeID, _ key: String) {
            guard let state = DrawnState.of(id, in: copy.file, registry: registry) else { return }
            record.shapes[id.description] = DrawingRecord.Shape(key: key, wrote: state)
        }
        for node in document.nodes { if let id = ids[node.key] { keep(id, node.key) } }
        // A pill under the key of the edge that makes it (no share), before any edge that shares it: what a later apply checks
        // a sharer's arrow against.
        let makersFirst = document.edges.filter { $0.pill != nil && $0.pill?.share == nil } + document.edges.filter { !($0.pill != nil && $0.pill?.share == nil) }
        for edge in makersFirst {
            guard let row = edges[edge.index] else { continue }
            if let arrow = row.arrow { keep(arrow, RecordKey.edge(edgeKeys[edge.index])) }
            if let pill = row.standIn, record.shapes[pill.description] == nil { keep(pill, RecordKey.pill(edgeKeys[edge.index])) }
        }
        // What a draw run joined stays the drawing's, as it is now, while the file holds it.
        for (text, shape) in before?.shapes ?? [:] {
            guard let uuid = UUID(uuidString: text), RecordKey.isJoined(shape.key, ShapeID(uuid)), record.shapes[text] == nil else { continue }
            keep(ShapeID(uuid), shape.key)
        }
        let name = name, records = records
        copy.transact(on: copy.board, DrawStyle.stepName) { transaction in
            transaction.byAgent = true
            records.write(name, record, &transaction)
        }
    }

    // MARK: Saying it

    private mutating func note(_ result: DrawResult, about: [Subject]) {
        for row in result.changes {
            guard row.line >= 1, row.line <= about.count else { continue }
            switch about[row.line - 1] {
            case .node(let key):
                if row.from == nil, row.id == ids[key]?.description { nodeRows[key, default: []].append(row) }
            case .edge(let index):
                if row.from != nil || row.arrow != nil { edgeRows[index] = row }
            }
        }
        for warning in result.warnings {
            // A count of the shapes past the twenty a run said is of one phase's, whose issues a later phase may mend: what the
            // drawing's shapes have is said at the end (`sayIssues`), and a query lists every issue.
            if warning.countsMore { continue }
            let subject = warning.line.flatMap { $0 >= 1 && $0 <= about.count ? about[$0 - 1] : nil }
            var key: String?, edge: Int?
            switch subject {
            case .node(let found)?: key = found
            case .edge(let index)?: edge = index
            case nil: break
            }
            let message = keyed(warning.message)
            let said = "\(key ?? "")|\(edge.map(String.init) ?? "")|\(message)"
            guard !warned.contains(said) else { continue }
            warned.insert(said)
            warnings.append((warning.about, DocumentResult.Warning(key: key, edge: edge, message: message, severity: warning.severity.rawValue,
                                                                   attribute: warning.attribute)))
        }
    }

    /// A run's refusal as the document's: each problem with the key of its line's node, or its edge's place.
    private func refusal(_ error: DrawError, about: [Subject]) -> DocumentError {
        let each = error.errors.isEmpty ? [error] : error.errors
        return DocumentError(each.map { problem in
            var key: String?, edge: Int?
            if let line = problem.line, line >= 1, line <= about.count {
                switch about[line - 1] {
                case .node(let found): key = found
                case .edge(let index): edge = index
                }
            }
            return DocumentError.Refusal(key: key, edge: edge, reason: problem.reason, message: keyed(problem.message), hint: problem.hint.map(keyed))
        })
    }

    /// A message with each id it names of the document's shapes said as that node's key.
    private func keyed(_ message: String) -> String {
        guard message.contains(ShapeName.idMark) else { return message }
        var out = message
        for (key, id) in ids where out.contains(id.description) {
            out = out.replacingOccurrences(of: "\(ShapeName.idMark)\(id)", with: quoted(key))
        }
        return out
    }

    private func verdicts(copy: CanvasEditor, current: [ShapeID: DrawnState], edges: [Int: DrawChange], dryRun: Bool) -> DocumentResult {
        var nodes: [DocumentResult.NodeVerdict] = []
        for node in document.nodes {
            guard let id = ids[node.key] else { continue }
            let rows = nodeRows[node.key] ?? []
            let did = made.contains(id) ? "created" : rows.contains(where: { $0.did != .unchanged }) ? "updated" : "unchanged"
            var overrode: [String]?
            if let then = before?.shapes[id.description]?.wrote, let now = current[id], let after = DrawnState.of(id, in: copy.file, registry: registry) {
                let theirs = now.changes(from: then), ours = Set(after.changes(from: now))
                let both = theirs.filter(ours.contains)
                if !both.isEmpty { overrode = both }
            }
            nodes.append(DocumentResult.NodeVerdict(key: node.key, did: did, id: dryRun && made.contains(id) ? nil : id.description,
                                                    at: copy.frame(inFile: id), overrode: overrode, problems: problems[node.key]))
        }
        let edgeVerdicts = document.edges.compactMap { edge -> DocumentResult.EdgeVerdict? in
            guard let row = edges[edge.index] else { return nil }
            let did = switch row.did {
            case .connected, .created: "created"
            case .unchanged: movedPills.contains(edge.index) ? "updated" : "unchanged"
            default: "updated"
            }
            let fresh = row.did == .connected
            return DocumentResult.EdgeVerdict(edge: edge.index, from: edge.from, to: edge.to, did: did,
                                              id: dryRun && fresh ? nil : row.arrow?.description, via: row.via)
        }
        let deleted = deletes.filter { gone in document.node(gone.key).map { ids[$0.key] != gone.id } ?? true }
            .map { DocumentResult.Deleted(key: $0.key, id: $0.id.description) }
        let board = top.owner.flatMap { copy.file.record($0) }.flatMap { registry.drawNaming?.name($0, registry) }
        return DocumentResult(drawing: name, dryRun: dryRun ? true : nil, on: DrawBoardSaid(board: top.description, title: board),
                              nodes: nodes, edges: edgeVerdicts, deleted: deleted, warnings: warnings.map(\.said))
    }
}

extension DrawError {
    /// The name a value wrote that this is about (`DrawTextLookup`): what a document's run puts off when it names a node not
    /// written yet.
    var lookedFor: String? {
        get { lookedForName }
        set { lookedForName = newValue }
    }
}
