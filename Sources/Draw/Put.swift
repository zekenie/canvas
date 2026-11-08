import Canvas
import CoreGraphics
import DrawScript
import Foundation
import Geometry

// Put: a program's shapes put down by a person, as `canvas draw` would draw them, with the person's rules in place of the
// agent's. A paste reader (Clipboard's) reads text into a `DrawPut`, a draw script as values with the way its new shapes are
// laid out, and `put` finds what the file already has by name, nearest first and never refused, makes the rest, lays the new
// shapes out in rows at draw's normal gap, lands the block beside the selection or centered on a point as Insert does, and draws
// it as one step named as the caller says, not as an agent's. It is the draw engine run another way, so a name finds its shape as
// every other writer of shapes finds one, and a value is written by the writer that owns it.

/// What a program puts down: a script as values (never text), how the shapes it makes are laid out, and the edges their values
/// imply.
public struct DrawPut: Sendable {
    /// Shapes by kind and title (or none), and the rows of their values in their writers' words, as the language has them.
    public var script: Script
    /// The statements that are new shapes the block lands together, by their `line`s, in layout rows: each row left to right
    /// at draw's normal gap, the rows top to bottom. A statement in none of them (or one that finds a shape the file has) is
    /// drawn where the engine places it.
    public var block: [[Int]]
    /// The edges a statement's values imply, by its `line` (a table's keys, from its rows): drawn as a writer's implied edges
    /// are (`DrawImpliedEdge`), each from the statement's shape to the one its far end finds. One whose far shape or row is
    /// found nowhere, or that can't be drawn, is left out, never refused.
    public var edges: [Int: [Edge]]

    public init(script: Script, block: [[Int]], edges: [Int: [Edge]] = [:]) {
        self.script = script
        self.block = block
        self.edges = edges
    }

    /// A shape a reader asks for: a kind, its title if it has one (and the titles of the containers it is in, a path the put
    /// finds it by first), its values as text, as a script's quoted values are (a property's writer takes them as it takes a
    /// script's), or as JSON, as a script's `[…]` and `{…}` are, and the edges its values imply.
    public struct Shape: Sendable {
        public var kind: String
        public var title: String?
        /// The titles of the containers it is in, outermost first (`["billing"]` for a table in the database billing): the shape
        /// at that path is found before any of its title alone, and failing that the put goes by its title. Nothing is made of
        /// them: a new shape lands beside the selection, in no container the path names.
        public var within: [String]
        public var values: [(key: String, text: String)]
        /// Values written as JSON text, each read as a script's `[…]` or `{…}` is.
        public var json: [(key: String, text: String)]
        /// The edges its values imply (a column's key): from it, at a row of it, to a shape a put finds by kind and name.
        public var edges: [Edge]

        public init(kind: String, title: String? = nil, within: [String] = [], values: [(key: String, text: String)] = [],
                    json: [(key: String, text: String)] = [], edges: [Edge] = []) {
            self.kind = kind
            self.title = title
            self.within = within
            self.values = values
            self.json = json
            self.edges = edges
        }

        /// What a statement calls it: its path when it is within containers, else its title.
        var name: ShapeName? {
            guard let title else { return nil }
            guard let head = within.first else { return .title(title) }
            return .path(ShapePath(head: .title(head), rest: Array(within.dropFirst()) + [title]))
        }
    }

    /// An edge a shape's values imply (a column's key to the row it names): from `fromRow` of the shape (nil: the shape as a
    /// whole) to `toRow` (nil: as a whole) of the shape of kind `toKind` called `toTitle`, within `toWithin` (a path found
    /// first), found as the put's own shapes are found (one the put draws, else the file's nearest), with the edge maker's
    /// attributes; `replacesType`: the type of edge the row has one of, which this re-aims (`DrawImpliedEdge`).
    /// `toRowOfShape`: for a row only the far shape can say (a table's primary key, which a key that names no column means), asked
    /// of the far shape the put found, as the file has it, when `toRow` is nil: the edge is left out where it gives none.
    public struct Edge: Sendable, Hashable {
        public var fromRow: String?
        public var toKind: String
        public var toTitle: String
        public var toWithin: [String]
        public var toRow: String?
        public var attributes: [String: String]
        public var replacesType: String?
        public var toRowOfShape: (@MainActor @Sendable (ShapeID, CanvasEditor) -> String?)?

        public init(fromRow: String?, toKind: String, toTitle: String, toWithin: [String] = [], toRow: String?,
                    attributes: [String: String] = [:], replacesType: String? = nil,
                    toRowOfShape: (@MainActor @Sendable (ShapeID, CanvasEditor) -> String?)? = nil) {
            self.fromRow = fromRow
            self.toKind = toKind
            self.toTitle = toTitle
            self.toWithin = toWithin
            self.toRow = toRow
            self.attributes = attributes
            self.replacesType = replacesType
            self.toRowOfShape = toRowOfShape
        }

        /// The far shape as a statement would name it.
        var toShape: Shape { Shape(kind: toKind, title: toTitle, within: toWithin) }

        /// Whether two are the same edge: a row asked of the far shape is only whether there is one.
        public static func == (a: Edge, b: Edge) -> Bool {
            a.fromRow == b.fromRow && a.toKind == b.toKind && a.toTitle == b.toTitle && a.toWithin == b.toWithin && a.toRow == b.toRow
                && a.attributes == b.attributes && a.replacesType == b.replacesType && (a.toRowOfShape == nil) == (b.toRowOfShape == nil)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(fromRow)
            hasher.combine(toKind)
            hasher.combine(toTitle)
            hasher.combine(toWithin)
            hasher.combine(toRow)
        }
    }

    /// Shapes in layout rows, numbered in order from 1: each row left to right, the rows top to bottom.
    public init(rows: [[Shape]]) {
        var statements: [Statement] = [], block: [[Int]] = [], edges: [Int: [Edge]] = [:]
        for row in rows {
            var lines: [Int] = []
            for shape in row {
                let line = statements.count + 1
                let attributes = shape.values.map { Attribute(key: $0.key, value: .quoted($0.text)) }
                    + shape.json.map { Attribute(key: $0.key, value: .json($0.text)) }
                let body = ShapeStatement(word: shape.kind, name: shape.name, attributes: attributes)
                statements.append(Statement(line: line, text: shape.kind, body: .shape(body)))
                lines.append(line)
                if !shape.edges.isEmpty { edges[line] = shape.edges }
            }
            if !lines.isEmpty { block.append(lines) }
        }
        self.init(script: Script(statements: statements, styles: []), block: block, edges: edges)
    }

    /// Whether it puts nothing down.
    public var isEmpty: Bool { script.statements.isEmpty }
}

/// Where a put lands.
public enum PutSite: Sendable {
    /// Beside these shapes, as Insert lands a shape (the middle of the view with none).
    case beside([ShapeID])
    /// Centered on a point of the board shown, world units.
    case centered(CGPoint)
}

/// Puts `block` down on the board `editor` shows: the shapes of it the file has (a shape of the statement's kind with its
/// title, anywhere in the file, the nearest winning: in the container the block lands in, then on the board shown, then the
/// file's order) are restated, any other statement makes a shape, new ones landing together at `site`. A title that finds
/// nothing, or a shape of another kind, is no match: a new shape is made. One step, `step`, not an agent's; a run that reaches two
/// boards is drawn on a rehearsal and taken in whole. Throws, committing nothing and leaving no step, where draw would refuse
/// (a board or container that takes nothing, a value its writer can't take). Returns the shapes made or restated, on the board shown.
@MainActor
@discardableResult
public func put(_ block: DrawPut, at site: PutSite, in editor: CanvasEditor, step: String = "Put") throws(DrawError) -> [ShapeID] {
    guard editor.session == nil, !editor.undoHistory.isPressHeld else {
        throw DrawError("someone is dragging or pressing on this board", reason: ScriptError.Reason.busy.rawValue, hint: "try again in a moment")
    }
    guard !editor.isBoardReadOnly else {
        throw DrawError("this board takes no shapes", reason: ScriptError.Reason.readOnly.rawValue, hint: "unlock what holds the board")
    }
    var plan = Putting(block, at: site, step: step, in: editor)
    return try plan.run()
}

/// A put being worked out: names found, runs by board, rows laid out, then drawn.
@MainActor
private struct Putting {
    let block: DrawPut
    let site: PutSite
    let step: String
    let editor: CanvasEditor
    let finding: PutFinding
    var shown: BoardID { finding.shown }

    /// Each statement as it will be drawn, by board, and what it names.
    private struct Planned {
        var statement: Statement
        var board: BoardID
        /// The id of the shape it makes or restates; nil for a statement that isn't a shape's.
        var id: ShapeID?
        var isNew: Bool
        /// Its original line, which `block` names it by.
        var original: Int
        /// The titles of the containers its name is within, outermost first (a path's), which a value may call it by.
        var within: [String] = []
        /// The edges its values imply, each with its far shape found (`DrawPut.edges`).
        var implied: [DrawImpliedEdge] = []
    }

    init(_ block: DrawPut, at site: PutSite, step: String, in editor: CanvasEditor) {
        self.block = block
        self.site = site
        self.step = step
        self.editor = editor
        finding = PutFinding(site: site, editor: editor)
    }

    mutating func run() throws(DrawError) -> [ShapeID] {
        let planned = name()
        var options = DrawOptions()
        options.program = true
        options.naming = .nearest
        options.byAgent = false
        options.step = step
        options.reserved = Set(planned.filter(\.isNew).compactMap(\.id))
        // The names a value may call a shape of the put by: its title, and, within containers, the path (`billing.status`). A title
        // shared by shapes the put names is the one in no container's, else none of them alone (a value that means one of them
        // calls it by its path).
        var bare: [String: ShapeID] = [:], inside: [String: [ShapeID]] = [:]
        for item in planned {
            // A far shape an implied edge names is keyed by its id, which no title can be.
            for edge in item.implied { if let far = UUID(uuidString: edge.to) { options.keys[edge.to] = ShapeID(far) } }
            guard case .shape(let shape) = item.statement.body, let id = item.id, let title = shape.newTitle ?? shape.title else { continue }
            if item.within.isEmpty {
                bare[title] = bare[title] ?? id
            } else {
                options.keys[(item.within + [title]).joined(separator: ".")] = id
                inside[title, default: []].append(id)
            }
        }
        for (title, id) in bare { options.keys[title] = id }
        for (title, ids) in inside where bare[title] == nil && ids.count == 1 { options.keys[title] = ids[0] }

        // Runs by board: the shown board's first, with every new shape and edge; a shape the file has elsewhere is restated on its
        // own board.
        var boards: [BoardID] = [shown]
        for item in planned where !boards.contains(item.board) { boards.append(item.board) }
        var scripts: [(board: BoardID, script: Script, lines: [Int: Int])] = []
        var implied: [BoardID: [Int: [DrawImpliedEdge]]] = [:]
        for board in boards {
            var lines: [Int: Int] = [:], statements: [Statement] = []
            for item in planned where item.board == board {
                var statement = item.statement
                statement.line = statements.count + 1
                lines[item.original] = statement.line
                statements.append(statement)
                if !item.implied.isEmpty { implied[board, default: [:]][statement.line] = item.implied }
            }
            scripts.append((board, Script(statements: statements, styles: board == shown ? block.script.styles : []), lines))
        }

        try layOut(planned, scripts, options: &options)

        let program = "canvas"
        let before = editor.document
        if scripts.count == 1 {
            var run = options
            run.board = shown
            run.implied = implied[shown] ?? [:]
            _ = try draw(parsed: scripts[0].script, dryRun: false, reveal: false, program: program, options: run, in: editor)
        } else {
            let copy = editor.rehearsal()
            for item in scripts {
                var run = options
                run.board = item.board
                run.implied = implied[item.board] ?? [:]
                if item.board != shown { run.places = [:] }
                _ = try draw(parsed: item.script, dryRun: false, reveal: false, program: program, options: run, in: copy)
            }
            guard editor.adopt(copy, named: step, byAgent: false) else {
                throw DrawError("the board changed while it was put down, so nothing was", reason: ScriptError.Reason.busy.rawValue, hint: "try again")
            }
        }
        // What it made or restated on the board shown: the shapes it named, and any it made without a name to find them by; not the
        // arrows its edges drew between them (a table's keys), which go with what they join.
        var seen: Set<ShapeID> = []
        let named = planned.compactMap(\.id).filter { editor.document[$0] != nil && seen.insert($0).inserted }
        let edgeKind = editor.registry.drawEdging.flatMap { $0.kind(editor.registry) }
        return named + editor.document.shapes.filter { before[$0.id] == nil && $0.kind != edgeKind && seen.insert($0.id).inserted }.map(\.id)
    }

    // MARK: Names

    /// Each statement with the shape it names: a shape the file has by that kind and title (at its path first, for a statement
    /// named by one), the nearest, or a new one under an id picked here; the titles other statements and values name them by
    /// resolved to those ids; and the edges each statement's values imply, with the shapes their far ends find.
    private func name() -> [Planned] {
        let registry = editor.registry
        let naming = registry.drawNaming
        let names = naming.map { FileNames(editor, naming: $0) }
        var planned: [Planned] = []
        var byTitle: [String: ShapeID] = [:]
        // The statement that first named each kind and title (or path) in the put: a later one of the same is the same shape, and
        // joins it.
        var first: [String: Int] = [:]
        // The shapes of the file the statements so far found: another statement's name never finds one of them again, so two
        // names that both fall back to one title (`auth.users` and `users`) are two shapes, the next nearest or a new one.
        var claimed: Set<ShapeID> = []
        for statement in block.script.statements {
            guard case .shape(var shape) = statement.body else {
                planned.append(Planned(statement: statement, board: shown, id: nil, isNew: false, original: statement.line))
                continue
            }
            var id: ShapeID?, board = shown, isNew = false, within: [String] = []
            let kind = ShapeKind(rawValue: shape.word)
            switch shape.name {
            case let name? where name.title != nil || name.path != nil:
                let written = name.title ?? name.path!.last
                if let path = name.path, case .title(let head) = path.head { within = [head] + path.rest.dropLast() }
                if let naming, let names, let key = Self.key(kind: kind, name: name, names: names, naming: naming) {
                    if let index = first[key], case .shape(var earlier) = planned[index].statement.body {
                        // A name written twice names one shape: the later statement's values join the earlier's (which keeps a
                        // key both write), and it is drawn once, so the put never makes two of a name nor writes one twice.
                        for attribute in shape.attributes where !earlier.attributes.contains(where: { $0.key == attribute.key }) {
                            earlier.attributes.append(attribute)
                        }
                        planned[index].statement.body = .shape(earlier)
                        continue
                    }
                    // A shape that cannot be changed is no match for a statement that gives it values: a new shape is made.
                    first[key] = planned.count
                    if let found = finding.place(kind: kind, name: name, writes: !shape.attributes.isEmpty, names: names, naming: naming, excluding: claimed) {
                        id = found.id
                        board = found.board
                        claimed.insert(found.id)
                    } else {
                        id = ShapeID()
                        isNew = true
                        shape.newTitle = written
                    }
                    if let folded = naming.fold(written) { byTitle[folded] = byTitle[folded] ?? id }
                    shape.name = .id(id!.description)
                }
            case nil:
                // Where nothing gives shapes names an id can't name one: the shape is drawn untitled and found by what it adds.
                isNew = true
                if naming != nil {
                    id = ShapeID()
                    shape.name = .id(id!.description)
                }
            default:
                break
            }
            if isNew, shape.container == nil, let holder = finding.holder { shape.container = .id(holder.description) }
            var named = statement
            named.body = .shape(shape)
            planned.append(Planned(statement: named, board: board, id: id, isNew: isNew, original: statement.line, within: within))
        }
        // The edges a statement's values imply, each to the shape its far end finds: one the put draws, else the file's nearest;
        // one that finds none is left out.
        if let naming, let names, !block.edges.isEmpty {
            for index in planned.indices {
                guard planned[index].id != nil, let edges = block.edges[planned[index].original] else { continue }
                for edge in edges {
                    let kind = ShapeKind(rawValue: edge.toKind)
                    guard let name = edge.toShape.name else { continue }
                    let far: ShapeID?
                    if let key = Self.key(kind: kind, name: name, names: names, naming: naming), let made = first[key] {
                        far = planned[made].id
                    } else {
                        far = finding.place(kind: kind, name: name, writes: false, names: names, naming: naming)?.id
                    }
                    guard let far else { continue }
                    // A row only the far shape can say (its primary key's), as the file has it: none, no edge.
                    var row = edge.toRow
                    if row == nil, let pick = edge.toRowOfShape {
                        row = pick(far, editor)
                        guard row != nil else { continue }
                    }
                    planned[index].implied.append(DrawImpliedEdge(fromRow: edge.fromRow, to: far.description, toRow: row,
                                                                  attributes: edge.attributes, replacesType: edge.replacesType))
                }
            }
        }
        // An edge naming a shape of the put by its title names the shape found or made (groups and deletes are not resolved: the readers give shapes and edges).
        guard let naming, !byTitle.isEmpty else { return planned }
        func resolved(_ name: ShapeName) -> ShapeName {
            guard case .title(let written) = name, let folded = naming.fold(written), let id = byTitle[folded] else { return name }
            return .id(id.description)
        }
        for index in planned.indices {
            switch planned[index].statement.body {
            case .edge(var edge):
                edge.from = resolved(edge.from)
                edge.to = resolved(edge.to)
                planned[index].statement.body = .edge(edge)
            default:
                break
            }
        }
        return planned
    }

    /// What tells one shape of a put from another: its kind and its title or path, folded; nil for a blank one.
    private static func key(kind: ShapeKind, name: ShapeName, names: FileNames, naming: DrawNaming) -> String? {
        switch name {
        case .title(let written): naming.fold(written).map { "\(kind.rawValue)\n\($0)" }
        case .path(let path): names.folded(path).map { "\(kind.rawValue)\n\($0.written)" }
        case .id: nil
        }
    }

    // MARK: Laying out

    /// Measures the new shapes, lays the block's out in rows at draw's normal gap, lands the box around them as Insert lands a
    /// shape, and gives each its place (`DrawOptions.places`, by the line of its run's statement).
    private func layOut(_ planned: [Planned], _ scripts: [(board: BoardID, script: Script, lines: [Int: Int])],
                        options: inout DrawOptions) throws(DrawError) {
        guard let shownRun = scripts.first(where: { $0.board == shown }) else { return }
        let isNew = Set(planned.filter(\.isNew).map(\.original))
        let rows = block.block.map { $0.filter { isNew.contains($0) && shownRun.lines[$0] != nil } }.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return }
        // How big each is drawn: the engine's own measure over the board, as it will draw them.
        var measuring = options
        measuring.board = shown
        let (board, fileNames) = try Drawing.board(for: shownRun.script, in: editor, pinned: shown)
        guard let reading = editor.reading(of: board) else {
            throw DrawError("the board went away", reason: ScriptError.Reason.internal.rawValue)
        }
        let drawing = try Drawing(shownRun.script, editor: editor, on: reading, fileNames: fileNames, options: measuring, program: "canvas")
        var rooms: [Int: CGSize] = [:]
        for item in drawing.items { rooms[item.statement.line] = item.room }

        let gap = GapName.normal.value
        var offsets: [Int: CGPoint] = [:]
        var width: CGFloat = 0, y: CGFloat = 0
        for (number, row) in rows.enumerated() {
            var x: CGFloat = 0, height: CGFloat = 0
            for original in row {
                let line = shownRun.lines[original]!
                let size = rooms[line] ?? .zero
                offsets[line] = CGPoint(x: x, y: y)
                x += size.width + gap
                height = max(height, size.height)
            }
            width = max(width, x - gap)
            y += height + (number == rows.count - 1 ? 0 : gap)
        }
        let size = CGSize(width: width, height: y)
        guard size.width > 0, size.height > 0 else { return }

        let origin: CGPoint
        switch site {
        case .centered(let point):
            origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        case .beside(let ids):
            let there = ids.filter { editor.document[$0] != nil }
            if let spot = Surroundings.insertionSpot(of: size, beside: there, in: editor) {
                origin = spot.origin
            } else if let surroundings = Surroundings(on: shown, moving: size, in: editor) {
                origin = surroundings.anywhere().rect.origin
            } else {
                origin = .zero
            }
        }
        for (line, offset) in offsets { options.places[line] = CGPoint(x: origin.x + offset.x, y: origin.y + offset.y) }
    }
}

/// How a put finds the file's shape a statement names (`Putting`, and `DrawPut.Shape.found` for a reader): of the statement's
/// kind, at its path first and else called its title, the nearest: in the container the block lands in, then on the board shown,
/// then the file's order (the board shown's first, then Topology's).
@MainActor
struct PutFinding {
    let editor: CanvasEditor
    let shown: BoardID
    /// The container the block lands in: the one the shapes it lands beside share.
    let holder: ShapeID?

    init(site: PutSite, editor: CanvasEditor) {
        self.editor = editor
        shown = editor.board
        if case .beside(let ids) = site {
            let containers = Set(ids.map { editor.shapeContext.container(of: $0) })
            holder = containers.count == 1 ? containers.first ?? nil : nil
        } else {
            holder = nil
        }
    }

    /// The shape of `kind` the file has that `name` finds, nil for none: a path's, else its title's (a title alone is its own).
    /// `writes`: a shape that cannot be changed is none.
    /// `excluding`: shapes already taken by another name of the put, which no other finds.
    func place(kind: ShapeKind, name: ShapeName, writes: Bool, names: FileNames, naming: DrawNaming, excluding: Set<ShapeID> = []) -> FileNames.Place? {
        let file = editor.file
        func admitted(_ places: [FileNames.Place]) -> [FileNames.Place] {
            places.filter { !excluding.contains($0.id) && file.record($0.id)?.kind == kind && !(writes && editor.isReadOnly(inFile: $0.id)) }
        }
        switch name {
        case .title(let written):
            guard let folded = naming.fold(written) else { return nil }
            return nearest(of: admitted(names.places[folded] ?? []))
        case .path(let path):
            if let folded = names.folded(path), let found = nearest(of: admitted(names.match(folded, board: shown).shapes)) { return found }
            return place(kind: kind, name: .title(path.last), writes: writes, names: names, naming: naming, excluding: excluding)
        case .id:
            return nil
        }
    }

    /// The nearest of shapes the file has by a name: in the container the block lands in, then on the board shown, then the
    /// file's order (the board shown's first, then Topology's).
    func nearest(of candidates: [FileNames.Place]) -> FileNames.Place? {
        func rank(_ place: FileNames.Place) -> Int {
            guard place.board == shown else { return 2 }
            return editor.file.record(place.id)?.container == holder ? 0 : 1
        }
        var best: (place: FileNames.Place, rank: Int)?
        for place in candidates {
            let ranked = rank(place)
            if best == nil || ranked < best!.rank { best = (place, ranked) }
        }
        return best?.place
    }
}
