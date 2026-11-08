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

/// What a program puts down: a script as values (never text), and how the shapes it makes are laid out.
public struct DrawPut: Sendable {
    /// Shapes by kind and title (or none), and the rows of their values in their writers' words, as the language has them.
    public var script: Script
    /// The statements that are new shapes the block lands together, by their `line`s, in layout rows: each row left to right
    /// at draw's normal gap, the rows top to bottom. A statement in none of them (or one that finds a shape the file has) is
    /// drawn where the engine places it.
    public var block: [[Int]]

    public init(script: Script, block: [[Int]]) {
        self.script = script
        self.block = block
    }

    /// A shape a reader asks for: a kind, its title if it has one, and its values as text, as a script's quoted values are
    /// (a property's writer takes them as it takes a script's).
    public struct Shape: Sendable {
        public var kind: String
        public var title: String?
        public var values: [(key: String, text: String)]

        public init(kind: String, title: String? = nil, values: [(key: String, text: String)] = []) {
            self.kind = kind
            self.title = title
            self.values = values
        }
    }

    /// Shapes in layout rows, numbered in order from 1: each row left to right, the rows top to bottom.
    public init(rows: [[Shape]]) {
        var statements: [Statement] = [], block: [[Int]] = []
        for row in rows {
            var lines: [Int] = []
            for shape in row {
                let line = statements.count + 1
                let attributes = shape.values.map { Attribute(key: $0.key, value: .quoted($0.text)) }
                let body = ShapeStatement(word: shape.kind, title: shape.title, attributes: attributes)
                statements.append(Statement(line: line, text: shape.kind, body: .shape(body)))
                lines.append(line)
            }
            if !lines.isEmpty { block.append(lines) }
        }
        self.init(script: Script(statements: statements, styles: []), block: block)
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
    let shown: BoardID
    /// The container the block lands in: the one the shapes it lands beside share.
    let holder: ShapeID?

    /// Each statement as it will be drawn, by board, and what it names.
    private struct Planned {
        var statement: Statement
        var board: BoardID
        /// The id of the shape it makes or restates; nil for a statement that isn't a shape's.
        var id: ShapeID?
        var isNew: Bool
        /// Its original line, which `block` names it by.
        var original: Int
    }

    init(_ block: DrawPut, at site: PutSite, step: String, in editor: CanvasEditor) {
        self.block = block
        self.site = site
        self.step = step
        self.editor = editor
        shown = editor.board
        if case .beside(let ids) = site {
            let containers = Set(ids.map { editor.shapeContext.container(of: $0) })
            holder = containers.count == 1 ? containers.first ?? nil : nil
        } else {
            holder = nil
        }
    }

    mutating func run() throws(DrawError) -> [ShapeID] {
        let planned = name()
        var options = DrawOptions()
        options.program = true
        options.naming = .nearest
        options.byAgent = false
        options.step = step
        options.reserved = Set(planned.filter(\.isNew).compactMap(\.id))
        for item in planned {
            guard case .shape(let shape) = item.statement.body, let id = item.id, let title = shape.newTitle ?? shape.title else { continue }
            options.keys[title] = id
        }

        // Runs by board: the shown board's first, with every new shape and edge; a shape the file has elsewhere is restated on its
        // own board.
        var boards: [BoardID] = [shown]
        for item in planned where !boards.contains(item.board) { boards.append(item.board) }
        var scripts: [(board: BoardID, script: Script, lines: [Int: Int])] = []
        for board in boards {
            var lines: [Int: Int] = [:], statements: [Statement] = []
            for item in planned where item.board == board {
                var statement = item.statement
                statement.line = statements.count + 1
                lines[item.original] = statement.line
                statements.append(statement)
            }
            scripts.append((board, Script(statements: statements, styles: board == shown ? block.script.styles : []), lines))
        }

        try layOut(planned, scripts, options: &options)

        let program = "canvas"
        let before = editor.document
        if scripts.count == 1 {
            var run = options
            run.board = shown
            _ = try draw(parsed: scripts[0].script, dryRun: false, reveal: false, program: program, options: run, in: editor)
        } else {
            let copy = editor.rehearsal()
            for item in scripts {
                var run = options
                run.board = item.board
                if item.board != shown { run.places = [:] }
                _ = try draw(parsed: item.script, dryRun: false, reveal: false, program: program, options: run, in: copy)
            }
            guard editor.adopt(copy, named: step, byAgent: false) else {
                throw DrawError("the board changed while it was put down, so nothing was", reason: ScriptError.Reason.busy.rawValue, hint: "try again")
            }
        }
        // What it made or restated on the board shown: the shapes it named, and any it made without a name to find them by.
        var seen: Set<ShapeID> = []
        let named = planned.compactMap(\.id).filter { editor.document[$0] != nil && seen.insert($0).inserted }
        return named + editor.document.shapes.map(\.id).filter { before[$0] == nil && seen.insert($0).inserted }
    }

    // MARK: Names

    /// Each statement with the shape it names: a shape the file has by that title and kind (the nearest), or a new one under an id
    /// picked here; the titles other statements and values name them by resolved to those ids.
    private func name() -> [Planned] {
        let registry = editor.registry
        let naming = registry.drawNaming
        let names = naming.map { FileNames(editor, naming: $0) }
        var planned: [Planned] = []
        var byTitle: [String: ShapeID] = [:]
        // The statement that first named each kind and title in the put: a later one of the same is the same shape, and joins it.
        var first: [String: Int] = [:]
        for statement in block.script.statements {
            guard case .shape(var shape) = statement.body else {
                planned.append(Planned(statement: statement, board: shown, id: nil, isNew: false, original: statement.line))
                continue
            }
            var id: ShapeID?, board = shown, isNew = false
            let kind = ShapeKind(rawValue: shape.word)
            switch shape.name {
            case .title(let written)?:
                if let naming, let names, let folded = naming.fold(written) {
                    let key = "\(shape.word)\n\(folded)"
                    if let index = first[key], case .shape(var earlier) = planned[index].statement.body {
                        // A title written twice names one shape: the later statement's values join the earlier's (which keeps a
                        // key both write), and it is drawn once, so the put never makes two of a name nor writes one twice.
                        for attribute in shape.attributes where !earlier.attributes.contains(where: { $0.key == attribute.key }) {
                            earlier.attributes.append(attribute)
                        }
                        planned[index].statement.body = .shape(earlier)
                        continue
                    }
                    // A shape that cannot be changed is no match for a statement that gives it values: a new shape is made.
                    let writes = !shape.attributes.isEmpty
                    let candidates = (names.places[folded] ?? []).filter {
                        editor.file.record($0.id)?.kind == kind && !(writes && editor.isReadOnly(inFile: $0.id))
                    }
                    first[key] = planned.count
                    if let found = nearest(of: candidates) {
                        id = found.id
                        board = found.board
                    } else {
                        id = ShapeID()
                        isNew = true
                        shape.newTitle = written
                    }
                    byTitle[folded] = byTitle[folded] ?? id
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
            if isNew, shape.container == nil, let holder { shape.container = .id(holder.description) }
            var named = statement
            named.body = .shape(shape)
            planned.append(Planned(statement: named, board: board, id: id, isNew: isNew, original: statement.line))
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

    /// The nearest of shapes the file has by a name: in the container the block lands in, then on the board shown, then the
    /// file's order (the board shown's first, then Topology's).
    private func nearest(of candidates: [FileNames.Place]) -> FileNames.Place? {
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
