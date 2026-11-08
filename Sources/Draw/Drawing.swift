import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import Foundation
import FuzzyMatching
import Topology

// Resolving a script against the board as the run starts: each statement's kind, the shape its
// title names (restated) or a new one, its attributes read by its kind's schema, its placements'
// targets; each edge's ends and attributes; each delete's shape or connections; each group's or
// ungroup's shapes. Problems that don't depend on each other are all found (up to
// `ScriptErrors.limit`), each statement's first.

/// A shape statement, resolved.
struct ShapeItem {
    let statement: Statement
    /// As written, and, for one `in` a container with nothing else to say where, against its
    /// top-left (`Drawing.contain`).
    var shape: ShapeStatement
    let kind: ShapeKind
    /// Its title, folded (the last part of a path); nil for an untitled shape.
    let title: String?
    /// The board shape it restates; nil for a new one.
    let existing: AnyShapeRecord?
    /// For a shape the statement makes: the frame it goes in, when the statement says (a path, or `in "F"`), nil for the top of
    /// the board. What tells two new shapes of one title apart (`Drawing.find(_:_:)`).
    var holderID: ShapeID?
    /// The path the statement names it by, folded, in a measure (which has no board to read a container from): what tells two new
    /// shapes of one title apart there.
    var pathKey: ShapePath?
    /// Its new title, folded (`title: "New"`), when it renames the shape.
    var rename: String?
    /// The shape as the statement leaves it, before it's placed: what the kind's tool places, or
    /// the shape restated, with its title and attributes set.
    var record: AnyShapeRecord
    /// How big it is, once drawn: as written, else what setting its attributes left it (a schema
    /// card as tall as its description), else as it is, or as its tool places it.
    var size: CGSize
    /// How much room it takes once drawn: its laid-out size, which is `size` for a kind laid out as it
    /// stores. What the layout places and a row reports; `size` is what is written and compared.
    var room: CGSize
    /// Where the frame it is laid out in starts, from the origin of the box it stores: zero for a kind laid out from its
    /// top-left, else what the kind's anchor makes of its size (a relationship type's pill is laid out about the middle
    /// of the box it stores, so its frame starts left of and above that box's origin). The layout places the frame, and
    /// the box is written where that puts the frame.
    var roomOffset: CGPoint = .zero
    /// What each placement's targets are, placement by placement.
    var targets: [[Found]] = []
    /// Its place among the layout's free boxes, if it moves.
    var free: Int?
    /// Where it goes: solved, or where it stays.
    var placed: CGRect?
    /// What it was pushed past, by name: only what it was kept clear of itself, not what a shape
    /// it moved along with was.
    var pushedPast: [String] = []
    /// What its statement wrote for each property a value writer joins (`DrawValueWriters`), by key, as the
    /// writer wrote it and before it joined what the shape held: what a report warns about.
    var written: JSONObject = [:]
    /// A board shape whose title is nearly this new one's.
    var nearMiss: String?
    /// The board shapes it sits on as zones where it's placed, in paint order: each wholly holds
    /// the shape where it is now, a shape it's placed against, the shape where it lands and others
    /// too, or the view it's placed against or drawn in, and it paints above them.
    var zones: [ShapeID] = []
    /// What `in "F"` names, when F holds shapes on its own board (a frame), as the run starts: the
    /// shape goes within it, and in it.
    var holder: AnyShapeRecord?
    /// What it stands for, as a message names it (a title in quotes, or an id as written), when it's a stand-in the run
    /// makes for an edge's end that's on another board (`Drawing.addStandIn`): the shape has no title or statement of its own,
    /// so its messages say what it's for.
    var standsFor: String?
    /// Whether its placements are the run's own and not written: a stand-in put beside the end of its edge (where
    /// `StandInRoute.spot` says), which gives way to what the script places and lists with the stand-ins beside the same
    /// shape. One its edge places (`EdgeStatement.clauses`, `in`) is placed as a shape statement is.
    var implied = false
    /// The id its statement wrote (`#7C1E…`, as written), when it names the shape by one: what a message calls a shape
    /// that has no title.
    var idWritten: String?
    /// Where its room's top-left goes exactly, when a program's run says (`DrawOptions.places`): placed there, never solved,
    /// pushed or pushing, and put down in or out of the containers it lands on as any shape is.
    var exact: CGPoint?

    /// A box a placement names, found.
    enum Found {
        /// A shape the script draws or restates: `items[index]`.
        case item(Int)
        /// A board shape the script doesn't mention.
        case shape(AnyShapeRecord)
        case board
        case view
        case origin
    }

    /// Whether the layout places it: it's new, restated with placements, or put exactly where a program's run says.
    var moves: Bool { existing == nil || !shape.clauses.isEmpty || exact != nil }
}

/// An edge statement, resolved.
struct EdgeItem {
    let statement: Statement
    let edge: EdgeStatement
    /// The rows its ends name (`"orders".customer_id`), found among the shapes' parts: nil for an end that is a whole shape.
    var fromPart: PartID?
    var toPart: PartID?
    /// The shapes its ends name: on the board, or, for an end elsewhere in the file, the shape there.
    let from: ShapeID
    let to: ShapeID
    /// How its ends are named, for its row and for messages: by title, or an id as written.
    let fromName: EndName
    let toName: EndName
    /// The attributes it gives the plugin that makes edges (DrawEdges'), as written.
    let attributes: [String: String]
    /// The rest it writes, its kind's own (an arrow's text), read by the kind's schema, set on the
    /// connection once it's made.
    let settings: JSONObject
    /// What it writes of the edge kind's identity keys, if it writes any: which of the pair's arrows it
    /// is about (`EdgeIdentity`).
    let identity: EdgeIdentity?
    /// The stand-in the run makes for it, if it makes one: a shape of the run, drawn before the arrow,
    /// which the arrow runs to (or from) in place of the end it stands for (`DrawStandIns.swift`).
    var standIn: NewStandIn?
    /// The arrow as the run will make it, made before the layout (`Drawing.layOut()`), so the shapes the
    /// run draws are laid out with the connections it draws. nil where it could not be made (`connect`
    /// says why where it applies), and for a run with no edges.
    var provisional: AnyShapeRecord?

    /// The shapes the arrow joins, as the run makes it: its ends, but for the stand-in in place of the
    /// one it stands for.
    var bound: (from: ShapeID, to: ShapeID) {
        guard let standIn else { return (from, to) }
        return standIn.place == .from ? (standIn.id, to) : (from, standIn.id)
    }
}

/// A delete statement, resolved: the shape it removes and every connection with an end on it (those
/// bound at both ends, and those with the other end free), or the connections `delete edge` removes.
struct DeleteItem {
    let statement: Statement
    let shape: AnyShapeRecord?
    let connections: [BoardConnection]
    /// Connections with one end on the shape and the other free: they join no two shapes, so
    /// nothing names their ends.
    var loose: [AnyShapeRecord] = []
    /// The boards the shape owns (a subboard's), the one under it and every board under that, and
    /// the shapes on them: all deleted with it.
    var boards = 0
    var boardShapes = 0
}

extension DeleteStatement {
    /// Whether it is a `delete edge` that writes attributes, which Draw reads as the identity of the arrows to remove.
    var writesIdentity: Bool {
        if case .edges(_, _, _, let attributes, _, _) = self { !attributes.isEmpty } else { false }
    }
}

/// A connection on the board: which shapes it joins.
struct BoardConnection {
    let record: AnyShapeRecord
    let from: ShapeID
    let to: ShapeID
}

@MainActor
struct Drawing {
    let editor: CanvasEditor
    /// What the command line that runs it is called, for the hints that name its commands.
    let program: String
    /// The board it draws on, as the run starts: the board shown, or another (`--on`).
    let target: BoardReading
    let registry: Registry
    let script: Script
    let naming: DrawNaming?
    let edging: DrawEdging?
    /// What edges are, if something makes them.
    let edgeKind: ShapeKind?
    /// The property keys that tell the edges of one pair apart (`DrawEdgeIdentities`), the edge kind's or not.
    let edgeIdentityKeys: [String]
    /// The window's part of the board; nil when the board isn't in one.
    let view: CGRect?

    private(set) var vocabularies: [ShapeKind: KindVocabulary] = [:]
    /// The board's shapes by name as the run starts; empty without DrawNames.
    private(set) var names = BoardNames()
    /// The board's connections as the run starts, once something has asked for them (a delete, or an
    /// edge that may go through a stand-in; `boardConnections()`); empty without DrawEdges.
    private var connections: [BoardConnection] = []
    private var connectionsRead = false
    /// The board shapes the run moves, restated with placements, once a stand-in asks (`movesWithRun`).
    private var movingShapes: Set<ShapeID>?
    /// The board's connections that don't join two shapes (an end left free), by each shape they
    /// name, as the run starts: a delete takes them with the shape.
    private var looseConnections: [ShapeID: [AnyShapeRecord]] = [:]

    private(set) var deletes: [DeleteItem] = []
    /// The rows `delete "X".row` takes out, one entry for each statement, in script order: taken out after the shapes
    /// are written (a statement may restate the shape too), and what they take along with them (keys) goes in the same step.
    private(set) var rowDeletes: [(statement: Statement, shape: ShapeID, parts: Set<PartID>)] = []
    /// The line each row deleted is deleted on, for an edge that names it.
    private var rowDeleteLines: [PartAddress: Int] = [:]
    /// The shapes `delete "X"` removes (their connections aside).
    private(set) var deletedShapes: Set<ShapeID> = []
    /// The boards the deleted shapes own, worked out once for the shapes deleted so far (a name asks it once each).
    let takenBoards = TakenBoards()
    /// Everything the deletes remove.
    private(set) var deleted: Set<ShapeID> = []
    var items: [ShapeItem] = []
    /// Each title of a shape statement, folded, and its items: more than one when the script makes or restates shapes of one
    /// title in different containers, which a lone title then can't name (the path can).
    private(set) var itemsByTitle: [String: [Int]] = [:]
    /// The item of each board shape a statement restates, by id (named by its title or its id).
    private(set) var itemByID: [ShapeID: Int] = [:]
    private(set) var edges: [EdgeItem] = []
    /// The places in `edges` of the edges that run from one shape to another (both ways for a two-headed one), so a statement
    /// finds the earlier ones it could repeat without reading every edge before it: a script of thousands of edges was
    /// quadratic in them.
    private var edgesByEnds: [EdgeEnds: [Int]] = [:]
    private struct EdgeEnds: Hashable {
        let from: ShapeID
        let to: ShapeID
    }
    /// The group and ungroup statements, resolved, in script order (`DrawGroups.swift`).
    var groupings: [GroupItem] = []
    /// The line of the statement that named each shape a group or ungroup names: a run says a shape's group once.
    var groupNamed: [ShapeID: Int] = [:]
    /// The stand-ins the run has made for edges, in order, for `share:` (`DrawStandIns.swift`).
    var madeStandIns: [MadeStandIn] = []
    /// The board's direct stand-ins by what each stands for, and what its arrows join, once something
    /// asks (`standInIndex`).
    var standInIndex: StandInRoute.Index?
    /// Each `delete edge`'s ends, for telling one written twice.
    private var edgeDeletes: [(from: ShapeID, to: ShapeID, eitherWay: Bool, line: Int, identity: EdgeIdentity?, rows: EdgeRows)] = []
    /// The rows a `delete edge` names at its ends.
    private struct EdgeRows: Equatable {
        let from: PartID?
        let to: PartID?
    }
    /// The stand-ins a delete took an arrow from (`delete edge`'s, or X's, which `delete "X"` takes),
    /// with the statement that did last, as a message says it: each goes too, once no arrow is left
    /// on it.
    private var standInsEmptied: [ShapeID: (statement: Statement, written: String)] = [:]

    /// Titles of statements that couldn't be resolved: whatever names them is left unresolved,
    /// without a second error.
    private(set) var unresolved: Set<String> = []
    /// The same for the ids of shapes whose statements couldn't be resolved.
    private(set) var unresolvedIDs: Set<ShapeID> = []
    /// The same for the paths, folded.
    private(set) var unresolvedPaths: Set<ShapePath> = []
    /// What placing found to say: pushes, a shape resized over another.
    var notes: [DrawWarning] = []
    private var errors: [DrawError] = []

    /// The file's names, when the script names shapes: what says a title it can't find here is on
    /// another board.
    let fileNames: FileNames?
    /// What stands in for what, when the script has an edge or a delete (`DrawStandIns.swift`); nil
    /// otherwise.
    let standIns: StandIns?
    /// What writes the texts a script gives properties of a media type some plugin writes, nil
    /// where none does.
    private(set) var textWriter: DrawTextWriter?
    /// The editor a measure reads names and types from, when it is given a board: the open file's, which a title in a
    /// script's value is found in and whose types its shapes are laid out by (read, never written). The run's own board
    /// is a scratch one.
    let namesBeyond: CanvasEditor?
    /// Whether this run only measures: a name it can't find is a warning and the shape is measured without it.
    let measuring: Bool
    /// What a program's run asks besides its script (`DrawOptions`): none for a script an agent types.
    let options: DrawOptions
    /// What measuring found to say (`MeasureResult.warnings`): each a line and a message.
    private(set) var measureWarnings: [(line: Int, message: String)] = []

    init(_ script: Script, editor: CanvasEditor, on target: BoardReading, fileNames: FileNames? = nil, namesBeyond: CanvasEditor? = nil,
         measuring: Bool = false, options: DrawOptions = DrawOptions(), program: String) throws(DrawError) {
        let registry = editor.registry
        self.editor = editor
        self.options = options
        self.program = program
        self.namesBeyond = namesBeyond
        self.measuring = measuring
        self.target = target
        self.fileNames = fileNames
        self.registry = registry
        self.script = script
        naming = registry.drawNaming
        edging = registry.drawEdging
        edgeKind = registry.drawEdging.flatMap { $0.kind(registry) }
        edgeIdentityKeys = registry.drawEdgeIdentityKeys
        // What stands in for what matters only to a script that joins shapes, or deletes them: the
        // stand-ins a delete's arrows ran into go with them.
        let hasDeletes = script.statements.contains(where: \.isDelete)
        standIns = (hasDeletes || script.statements.contains(where: \.joinsShapes)) && edgeKind != nil ? registry.standIns : nil
        // Where the view is headed, if it's gliding (a --reveal a moment ago): the view the drawing
        // is seen in once it settles; on a board not shown, the view it would be shown with. The
        // part of it the host leaves clear (below the path's pill over a subboard), as every fit is.
        view = target.view
        if let fileNames {
            names = BoardNames(fileNames.entries(on: target.board))
        } else if let naming, script.mentionsTitles {
            names = BoardNames(target.document, naming: naming, registry: registry)
        }
        // What connects to what, for the deletes (edges read the transaction's document).
        if hasDeletes { _ = boardConnections() }

        for statement in script.statements {
            guard case .delete(let delete) = statement.body, !delete.writesIdentity else { continue }
            do throws(DrawError) { try resolve(delete, statement) } catch { keep(error) }
        }
        // A stand-in the deletes left with no arrow goes with them.
        do throws(DrawError) { try retireEmptiedStandIns() } catch { keep(error) }
        for statement in script.statements {
            guard case .shape(let shape) = statement.body else { continue }
            do throws(DrawError) {
                try find(shape, statement)
            } catch {
                keep(error)
                if let title = shape.title { unresolved.insert(fold(title) ?? title) }
                if let text = shape.name?.id, let uuid = UUID(uuidString: text) { unresolvedIDs.insert(ShapeID(uuid)) }
                if let path = shape.name?.path, let naming, let folded = Self.folded(path, naming: naming) { unresolvedPaths.insert(folded) }
            }
        }
        // Every title the script draws, restates or renames to is known: a text may name them now.
        let formats = registry.drawTextFormats
        if !formats.isEmpty || !registry.drawValueWriters.isEmpty || !options.implied.isEmpty {
            let lookup = DrawTextLookup(editor: namesBeyond ?? editor, target: target, naming: naming, items: items, itemsByTitle: itemsByTitle,
                                        unresolved: unresolved, deleted: deletedShapes, fileNames: fileNames, keys: options.keys,
                                        nearest: options.naming == .nearest)
            textWriter = DrawTextWriter(registry: registry, formats: formats, lookup: lookup)
        }
        // A `delete edge` that says which arrow (`is: "T"`) names a type by its title, which only a text
        // writer can read; its ends' arrows go as the others' did.
        if script.statements.contains(where: { if case .delete(let delete) = $0.body { delete.writesIdentity } else { false } }) {
            for statement in script.statements {
                guard case .delete(let delete) = statement.body, delete.writesIdentity else { continue }
                do throws(DrawError) { try resolve(delete, statement) } catch { keep(error) }
            }
            do throws(DrawError) { try retireEmptiedStandIns() } catch { keep(error) }
        }
        for index in items.indices {
            do throws(DrawError) { try complete(index) } catch { keep(error) }
        }
        for statement in script.statements {
            guard case .edge(let edge) = statement.body else { continue }
            do throws(DrawError) { try resolve(edge, statement) } catch {
                // Measuring says a name it can't find, and lays the shapes out without the edge.
                if measuring, error.fromNameLookup {
                    measureWarnings.append((statement.line, error.message + "; measured without it"))
                } else {
                    keep(error)
                }
            }
        }
        // The edges the values a script writes imply (a column's line's `→`), on their statements' lines, after the script's own: one
        // the same as an edge the script writes is that edge, drawn once.
        if registry.drawValueWriters.values.contains(where: \.impliesEdges) || !options.implied.isEmpty {
            // A person's put is never refused for an edge its values imply: one that can't be drawn (a row the far shape hasn't, a
            // shape on another board) is left out, as is a statement's whose writer can't say its edges.
            let leavingOut = options.naming == .nearest
            for statement in script.statements {
                guard case .shape(let shape) = statement.body else { continue }
                do throws(DrawError) {
                    for (edge, implied) in try impliedEdges(of: shape, statement) {
                        let written = Statement(line: statement.line, text: statement.text, body: .edge(edge))
                        if leavingOut {
                            do throws(DrawError) { try resolve(edge, written, implied: implied) } catch { continue }
                        } else {
                            try resolve(edge, written, implied: implied)
                        }
                    }
                } catch {
                    if leavingOut { continue }
                    if measuring, error.fromNameLookup {
                        measureWarnings.append((statement.line, error.message + "; measured without it"))
                    } else {
                        keep(error)
                    }
                }
            }
        }
        // Groups and ungroups name shapes the script draws as well as the board's, so every shape is known.
        for statement in script.statements {
            switch statement.body {
            case .group(let group):
                do throws(DrawError) { try resolve(group, ungrouping: false, statement) } catch { keep(error) }
            case .ungroup(let group):
                do throws(DrawError) { try resolve(group, ungrouping: true, statement) } catch { keep(error) }
            case .shape, .edge, .delete:
                continue
            }
        }
        for style in script.styles {
            do throws(DrawError) { try check(style) } catch { keep(error) }
        }
        guard errors.isEmpty else { throw collected(errors) }
        layOut()
    }

    /// Works out how much room each shape takes once drawn (`ShapeItem.room`): the frame its kind lays
    /// it out in, with the script's own shapes read as the file's (a type and its instance drawn
    /// together, a stretch and the gauge it names), the connections the script draws laid in beside them
    /// (`provisionalConnections()`: an end gives its type's notes a row), and a board shape the script
    /// doesn't restate read as it is, but for those it deletes, shapes and connections, which are not there.
    /// Only the size is kept: a shape is placed where the layout says, so its origin is its own. What draw
    /// places and reports, and `canvas measure` answers with, so the two agree.
    private mutating func layOut() {
        // No shape to lay out, no room to ask: the arrows are not made for nothing (an edge-only run).
        guard !items.isEmpty else { return }
        // Over the open file's own context when a measure is given one: its services keep the types and the ends
        // the script's shapes are laid out by, and nothing is written (the records are read as the file's).
        let base = namesBeyond?.shapeContext ?? target.shapes
        let connections = provisionalConnections()
        let context = base.layingOut(with: items.map(\.record) + connections, removing: deleted)
        for index in items.indices {
            var sized = items[index].record
            sized.box = CGRect(origin: items[index].existing?.box?.origin ?? .zero, size: items[index].size)
            let frame = context.frame(of: sized)
            items[index].room = frame?.size ?? items[index].size
            items[index].roomOffset = frame.map { CGPoint(x: $0.minX - sized.box!.minX, y: $0.minY - sized.box!.minY) } ?? .zero
        }
    }

    /// The arrows the run will draw or change, made as `connect` makes them (`connection(for:matches:…)`, the one
    /// function) over a document of the ends alone, to be laid in beside the shapes: a run that draws an end and
    /// the notes of its type together is laid out with the row the end gives. An arrow the run leaves as it is
    /// is not laid in (the file has it), and one that can't be made contributes nothing and says nothing:
    /// `connect` throws what it throws, where it throws it. Each is kept on its edge for `connect` to hold the
    /// arrow it draws to (debug builds).
    private mutating func provisionalConnections() -> [AnyShapeRecord] {
        guard let edging, let edgeKind, !edges.isEmpty else { return [] }
        // A measure matches the arrows of the board it is given; a draw, those of its board as the run starts.
        let board = measuring ? namesBeyond?.document : target.document
        var drawn: [BoardConnection]
        if measuring {
            drawn = namesBeyond.map { Self.connections(in: $0.document, kind: edgeKind, edging: edging, registry: registry) } ?? []
        } else {
            drawn = boardConnections().filter { !deleted.contains($0.record.id) }
        }
        let place = Dictionary(drawn.enumerated().map { ($1.record.id, $0) }, uniquingKeysWith: { first, _ in first })
        let itemByID = Dictionary(items.enumerated().map { ($1.record.id, $0) }, uniquingKeysWith: { first, _ in first })
        func record(_ id: ShapeID) -> AnyShapeRecord? {
            itemByID[id].map { items[$0].record } ?? board?[id] ?? editor.file.record(id) ?? namesBeyond?.shape(inFile: id)
        }
        var made: [AnyShapeRecord] = []
        // The connections that join each pair, as `draw` keeps them while it connects: the board's, then the run's
        // own, which are these arrows (ids of their own, never the committed ones: what a maker reads of an arrow
        // beside is its bend and its ends, so the ends alone are given the arrows beside, as the transaction has them).
        var pairs = Self.pairArrows(of: drawn)
        var arrows = Dictionary(drawn.map { ($0.record.id, $0.record) }, uniquingKeysWith: { first, _ in first })
        for index in edges.indices {
            let edge = edges[index]
            let document = board ?? target.document
            let matches = addressedMatches(from: edge.from, to: edge.to, bothHeads: edge.edge.bothHeads, among: drawn, in: document, identity: edge.identity,
                                           parts: (edge.fromPart, edge.toPart))
            guard matches.count < 2 else { continue }
            let ends = matches.first.map { ($0.connection.from, $0.connection.to) } ?? edge.bound
            // The ends alone, as the run leaves them (an item's record is the shape the run draws).
            var held: [AnyShapeRecord] = []
            for id in [ends.0, ends.1] where !held.contains(where: { $0.id == id }) {
                guard let end = record(id) else { break }
                held.append(end)
            }
            guard held.count == Set([ends.0, ends.1]).count else { continue }
            let alone = CanvasDocument(shapes: held + (pairs[[ends.0, ends.1]] ?? []).compactMap { arrows[$0] })
            guard let arrow = try? connection(for: edge, matches: matches, beside: pairs, edging: edging, kind: edgeKind, in: alone,
                                              shapes: ShapeContext(document: alone, registry: registry)) else { continue }
            edges[index].provisional = arrow.record
            if let match = matches.first {
                if match.connection.record == arrow.record { continue }
                // An arrow a statement changes is the arrow the next statement finds, as `apply` has it: a plain
                // one that took a type is no longer the pair's plain arrow.
                if let at = place[arrow.record.id], let ends = edging.ends(arrow.record, registry) {
                    drawn[at] = BoardConnection(record: arrow.record, from: ends.from, to: ends.to)
                    arrows[arrow.record.id] = arrow.record
                }
            }
            made.append(arrow.record)
            if matches.isEmpty {
                pairs[[arrow.ends.from, arrow.ends.to], default: []].append(arrow.record.id)
                arrows[arrow.record.id] = arrow.record
            }
        }
        return made
    }

    /// Keeps a statement's error with the others (but one that only follows from another's).
    private mutating func keep(_ error: DrawError) {
        if error.reason != Self.skipped { errors.append(error) }
    }

    /// What a statement that depends on one that couldn't be resolved throws: no error of its own.
    static let skipped = "skipped"
    func skip() -> DrawError { DrawError("", reason: Self.skipped) }

    /// Whether the run, placed, changes or deletes this shape (so an edit under way should end
    /// first): a shape restated as it is isn't changed, nor a connection whose statement writes
    /// none of its kind's own attributes (an arrow's text) differently (re-aiming it changes
    /// nothing typed into it).
    func changes(_ id: ShapeID) -> Bool {
        if deleted.contains(id) || items.contains(where: { $0.existing?.id == id && $0.record != $0.existing }) { return true }
        if rowDeletes.contains(where: { $0.shape == id }) { return true }
        guard !edges.isEmpty, let edging, let record = editor.document[id], record.kind == edgeKind,
              let ends = edging.ends(record, registry) else { return false }
        let drawn = [BoardConnection(record: record, from: ends.from, to: ends.to)]
        return edges.contains { edge in
            // An arrow of another identity than the statement writes isn't its edge. A plain one is, as
            // far as this arrow alone says (it takes the identity, if it's the pair's only plain one:
            // not decided without the pair's others, and an edit ending first is no harm).
            let joins = !addressedMatches(from: edge.from, to: edge.to, bothHeads: edge.edge.bothHeads, among: drawn,
                                          in: editor.document, identity: edge.identity, parts: (edge.fromPart, edge.toPart)).isEmpty
            // What it writes of the identity it is found by is that already, as `connect` leaves it.
            let held = edge.identity.map { $0.matches(record) } ?? false
            return joins && edge.settings.contains { (held && edge.identity?.written[$0.key] != nil) ? false : !Self.alreadyHas(record, $0.key, $0.value, in: registry) }
        }
    }

    // MARK: Names

    func fold(_ title: String) -> String? { naming?.fold(title) }

    /// A title as written, folded, or why it can't be one.
    func folded(_ written: String, _ statement: Statement) throws(DrawError) -> String {
        guard naming != nil else {
            throw DrawError(statement, .noNames, "titles name shapes, and nothing here gives shapes names",
                            hint: "leave titles out: without a plugin that names shapes, no shape can be named or found by name")
        }
        guard let folded = fold(written) else {
            throw DrawError(statement, .syntax, "a title can't be blank", hint: "leave it out for an untitled shape")
        }
        return folded
    }

    /// The board shapes called this, but those the script deletes.
    func boardShapes(called title: String) -> [ShapeID] {
        (names.ids[title] ?? []).filter { !deletedShapes.contains($0) }
    }

    /// Whether a board shape the script doesn't delete is called this.
    func isOnBoard(_ title: String) -> Bool {
        names.ids[title]?.contains { !deletedShapes.contains($0) } == true
    }

    /// The board shape called this, if one is, or why not: none, or several (each listed with its kind and its path).
    func boardShape(called title: String, _ statement: Statement) throws(DrawError) -> AnyShapeRecord? {
        let found = boardShapes(called: title)
        guard found.count < 2 || options.naming == .nearest else {
            throw ambiguous(quoted(title), found.compactMap { target.document[$0] }.map(ShapeItem.Found.shape), statement)
        }
        return found.first.flatMap { target.document[$0] }
    }

    /// A shape a statement names by title: one the script draws or restates, else one on the
    /// board; nil if it's one a statement that couldn't be resolved draws. `mine` is the title of
    /// the statement's own shape, never what it meant (placed against itself, it's `circular`). `inside` is the frame the
    /// statement puts its shape in (`in "F"`): a title is found inside it first, then as anywhere else. A title that two
    /// shapes of the script have, or that two of the board have, is `ambiguous_title`: the path names the one.
    func find(_ title: String, _ statement: Statement, for what: String, mine: String? = nil, inside: ShapeID? = nil) throws(DrawError) -> ShapeItem.Found? {
        if let inside, let found = try found(title, inside: inside, statement) { return found }
        let drawn = itemsByTitle[title] ?? []
        if drawn.count > 1 { throw ambiguous(quoted(title), drawn.map(ShapeItem.Found.item), statement) }
        if let index = drawn.first { return .item(index) }
        if unresolved.contains(title) { return nil }
        if let record = try boardShape(called: title, statement) { return .shape(record) }
        throw notFound(title, statement, for: what, mine: mine, elsewhere: true)
    }

    /// Why a title no shape on the board has isn't found: the script deletes the shape, it's on
    /// another board (an error where `elsewhere` is, as for a placement; an edge's end looks there
    /// itself), or nothing is called that, with the titles like it.
    func notFound(_ title: String, _ statement: Statement, for what: String, mine: String? = nil, elsewhere: Bool) -> DrawError {
        if names.ids[title] != nil {
            return DrawError(statement, .unknownTitle, "\(what) \(quoted(title)), which this script deletes",
                             hint: "draw \(quoted(title)) again after deleting it, or leave it out")
        }
        if elsewhere, let other = fileNames?.boards(of: title).first(where: { $0 != target.board }) {
            return severalBoards(title, on: other, statement, for: what)
        }
        let drawn = items.compactMap(\.title)
        let guesses = Suggestions.closest(to: title, among: (names.ordered.filter(isOnBoard) + drawn).filter { $0 != mine })
        return DrawError(statement, .unknownTitle, "there's no shape called \(quoted(title))",
                         hint: guesses.isEmpty ? "a title is one the board has as the script starts, or one the script draws"
                                   : "did you mean \(listed(guesses.map(quoted), or: true))?")
    }

    /// `edge "A" -> "B" is drawn to "B", which is on "P"'s board, and this script draws on the root
    /// board`: a title that's on another board than the one the run draws on, where that can't be.
    func severalBoards(_ title: String, on other: BoardID, _ statement: Statement, for what: String, hint: String? = nil) -> DrawError {
        severalBoards(said: quoted(title), on: other, statement, for: what, hint: hint)
    }

    /// The same for a shape a message already names (a title in quotes, or an id as written).
    func severalBoards(said: String, on other: BoardID, _ statement: Statement, for what: String, hint: String? = nil) -> DrawError {
        guard let naming else { return DrawError(statement, .internal, "\(what) \(said), which is on another board") }
        return DrawError(statement, .severalBoards,
                         "\(what) \(said), which is on \(FileNames.named(other, in: editor, naming: naming)), and this script draws on \(FileNames.named(target.board, in: editor, naming: naming))",
                         hint: hint ?? "a run draws on one board, and a shape is placed or connected only to shapes on its own")
    }

    // MARK: Deletes

    private mutating func resolve(_ delete: DeleteStatement, _ statement: Statement) throws(DrawError) {
        switch delete {
        case .row(let name, let row):
            let record: AnyShapeRecord, said: String
            switch name {
            case .title(let written):
                let title = try folded(written, statement)
                guard let found = try boardShape(called: title, statement) else {
                    if deletes.contains(where: { $0.shape.flatMap(names.name(of:)) == title }) {
                        throw DrawError(statement, .duplicate, "\(quoted(title)) is deleted, and so its rows are", hint: "leave \(Keyword.delete.rawValue) \(quoted(title))\(ShapeName.writtenRow(row)) out")
                    }
                    let guesses = Suggestions.closest(to: title, among: names.ordered)
                    throw DrawError(statement, .unknownTitle, "there's no shape called \(quoted(title)) to delete a row of",
                                    hint: guesses.isEmpty ? nil : "did you mean \(listed(guesses.map(quoted), or: true))?")
                }
                (record, said) = (found, quoted(title))
            case .path(let written):
                let path = try folded(written, statement)
                let resolution = try resolve(path, statement)
                let named = resolution.here.compactMap { target.document[$0.id] }
                if named.count > 1 { throw ambiguous(path.written, named.map(ShapeItem.Found.shape), statement) }
                guard let found = named.first else {
                    if resolution.deleted {
                        throw DrawError(statement, .duplicate, "\(path.written) is deleted, and so its rows are", hint: "leave \(Keyword.delete.rawValue) \(path.written)\(ShapeName.writtenRow(row)) out")
                    }
                    throw pathNotFound(resolution, statement, for: Keyword.delete.rawValue, elsewhere: false, suffix: " to delete a row of")
                }
                (record, said) = (found, path.written)
            case .id(let text):
                let id = try shapeID(text, statement), mark = name.written
                let found = try fileShape(withID: id, written: mark, statement)
                guard found.board == target.board else { throw severalBoards(said: mark, on: found.board, statement, for: "\(Keyword.delete.rawValue) names") }
                (record, said) = (found.record, self.said(found.record, written: mark))
            }
            if deletedShapes.contains(record.id) {
                throw DrawError(statement, .duplicate, "\(said) is deleted, and so its rows are", hint: "leave \(Keyword.delete.rawValue) \(name.written)\(ShapeName.writtenRow(row)) out")
            }
            let part = try self.part(named: row, of: record, said: said, statement)
            try writable(record, statement, said, so: "its rows can't be deleted")
            // A kind that lists rows but can't take one out by id (`PartedShape.removing`) is refused here, not at the commit.
            guard registry.removing([part], from: record) != nil else {
                throw DrawError(statement, .unsupported, "\(said) is \(indefinite(record.kind)), whose rows draw can't delete",
                                hint: "delete the shape, or change its rows by hand")
            }
            if let line = rowDeleteLines[PartAddress(record.id, part: part)] {
                throw DrawError(statement, .duplicate, "\(said)\(ShapeName.writtenRow(row)) is deleted twice, on line \(line) and here", hint: "delete it once")
            }
            rowDeleteLines[PartAddress(record.id, part: part)] = statement.line
            // One entry for each statement, so a row and its keys are said on the line that took them.
            rowDeletes.append((statement, record.id, [part]))
        case .shape(let name):
            // What the shape is called in a message, and what the statement is called in the one a stand-in's retiring says.
            let record: AnyShapeRecord, said: String, deleting: String
            switch name {
            case .title(let written):
                let title = try folded(written, statement)
                guard let found = try boardShape(called: title, statement) else {
                    if deletes.contains(where: { $0.shape.flatMap(names.name(of:)) == title }) {
                        throw DrawError(statement, .duplicate, "\(quoted(title)) is deleted twice", hint: "delete it once")
                    }
                    let guesses = Suggestions.closest(to: title, among: names.ordered)
                    throw DrawError(statement, .unknownTitle, "there's no shape called \(quoted(title)) to delete",
                                    hint: guesses.isEmpty ? nil : "did you mean \(listed(guesses.map(quoted), or: true))?")
                }
                (record, said, deleting) = (found, quoted(title), "\(Keyword.delete.rawValue) \(quoted(title))")
            case .path(let written):
                let path = try folded(written, statement)
                let resolution = try resolve(path, statement)
                let named = resolution.here.compactMap { target.document[$0.id] }
                if named.count > 1 { throw ambiguous(path.written, named.map(ShapeItem.Found.shape), statement) }
                guard let found = named.first else {
                    if resolution.deleted { throw DrawError(statement, .duplicate, "\(path.written) is deleted twice", hint: "delete it once") }
                    throw pathNotFound(resolution, statement, for: Keyword.delete.rawValue, elsewhere: false, suffix: " to delete")
                }
                (record, said, deleting) = (found, path.written, "\(Keyword.delete.rawValue) \(path.written)")
            case .id(let text):
                let id = try shapeID(text, statement), mark = name.written
                let found = try fileShape(withID: id, written: mark, statement)
                guard found.board == target.board else { throw severalBoards(said: mark, on: found.board, statement, for: "\(Keyword.delete.rawValue) names") }
                if deletedShapes.contains(id) { throw DrawError(statement, .duplicate, "\(mark) is deleted twice", hint: "delete it once") }
                (record, said, deleting) = (found.record, self.said(found.record, written: mark), "\(Keyword.delete.rawValue) \(mark)")
            }
            try writable(record, statement, said, so: "it can't be deleted")
            // The board it owns goes with it, and every board under that (a transaction takes them):
            // not at all if one of them holds a read-only shape, as the Finder won't trash a folder
            // holding a locked file.
            let file = editor.file, boards = file.subtree(ownedBy: [record.id])
            // Drawing on a board above the one shown, the window is inside what it'd take.
            if let shown = boards.first(where: editor.boardPath.contains) {
                let holds = shown == editor.board ? "the board the window shows" : "a board above the one the window shows"
                throw DrawError(statement, .boardShown, "\(said) holds \(holds), so it can't be deleted",
                                hint: "show a board above it first: \(program) show --root")
            }
            if boards.contains(where: { file[$0].shapes.contains(where: registry.isReadOnly) }) {
                throw DrawError(statement, .readOnly, "\(said) holds a read-only shape (locked, say) on its board, so it can't be deleted",
                                hint: "leave it out of the script, or ask the user to unlock what's on its board")
            }
            // A row of it (or of a shape on a board it owns) deleted by an earlier line: the shape takes its rows along.
            let taken = Set([record.id] + boards.flatMap { file[$0].shapes.map(\.id) })
            if let rows = rowDeletes.first(where: { taken.contains($0.shape) }) {
                throw DrawError(statement, .duplicate, "\(said) is deleted, and so are the rows of \(quoted(target.document[rows.shape].flatMap(names.name(of:)) ?? "it")) deleted on line \(rows.statement.line)",
                                hint: "leave the row delete or this one out")
            }
            let attached = connections.filter { ($0.from == record.id || $0.to == record.id) && !deleted.contains($0.record.id) }
            let loose = (looseConnections[record.id] ?? []).filter { !deleted.contains($0.id) }
            for connection in attached.map(\.record) + loose {
                try writable(connection, statement, "one of \(said)'s connections", so: "\(said) can't be deleted with it")
            }
            deletes.append(DeleteItem(statement: statement, shape: record, connections: attached, loose: loose, boards: boards.count,
                                      boardShapes: boards.reduce(0) { $0 + file[$1].shapes.count }))
            deletedShapes.insert(record.id)
            deleted.insert(record.id)
            deleted.formUnion(attached.map(\.record.id))
            deleted.formUnion(loose.map(\.id))
            // A stand-in at the other end of one of its arrows goes too, as `delete edge`'s does, once
            // the run leaves it no arrow: it has no title for a script to delete it by.
            for connection in attached {
                let other = connection.from == record.id ? connection.to : connection.from
                if standIn(at: other, in: target.document) != nil {
                    standInsEmptied[other] = (statement, deleting)
                }
            }
        case .edges(let fromWritten, let toWritten, let eitherWay, let attributes, let fromRow, let toRow):
            let pair = "\(fromWritten.written)\(fromRow.map(ShapeName.writtenRow) ?? "") \(eitherWay ? EdgeArrow.both.rawValue : EdgeArrow.forward.rawValue) "
                + "\(toWritten.written)\(toRow.map(ShapeName.writtenRow) ?? "")"
            let written = ([pair] + attributes.map { "\($0.key): \($0.value.written)" }).joined(separator: " ")
            guard let edgeKind else { throw noEdges(statement) }
            // Only what tells edges apart: `delete edge "A" -> "B" is: "T"` takes that one.
            let connector = vocabulary(of: edgeKind)
            let keys = identityKeys(connector) ?? []
            var settings: JSONObject = [:]
            for attribute in attributes {
                guard keys.contains(attribute.key) else {
                    let takes = keys.isEmpty ? "no attribute" : "\(keys.map { "\($0):" }.joined(separator: ", ")) and no other attribute"
                    throw DrawError(statement, .unknownAttribute, "delete edge takes \(takes), not \(attribute.key):",
                                    hint: keys.isEmpty ? "write delete edge \(pair)" : "write delete edge \(pair) \(keys.map { "\($0): …" }.joined(separator: " ")) to remove one of them")
                }
                settings[attribute.key] = try edgeValue(attribute, connector, written: "\(Keyword.delete.rawValue) \(Keyword.edge.rawValue) \(pair)", statement)
            }
            let identity = EdgeIdentity(keys: keys, settings: settings)
            // An end a `delete` above deletes is still that shape: the delete takes its edges, so
            // this asks for what's done already, which is fine, as it is written the other way round.
            // One that's on another board is the shape there, whose stand-in on this one the edge goes
            // through (`DrawStandIns.swift`). Named by id, it is found as an edge's end is, the shape this script
            // deletes included.
            func none(_ missing: String) -> DrawError {
                let drawn = script.statements.contains { other in
                    if case .shape(let shape) = other.body, let title = shape.title { return fold(title) == missing } else { return false }
                }
                if names.ids[missing] != nil || drawn { return nothingToDelete(statement, written) }
                return DrawError(statement, .unknownTitle, "there's no shape called \(quoted(missing))",
                                 hint: "delete edge takes shapes the file has as the script starts")
            }
            func end(_ name: ShapeName) throws(DrawError) -> (found: EdgeEndFound, said: String) {
                switch name {
                case .path(let text):
                    let path = try folded(text, statement)
                    let resolution = try resolve(path, statement)
                    let here = resolution.here.compactMap { target.document[$0.id] }
                    if here.count > 1 { throw ambiguous(path.written, here.map(ShapeItem.Found.shape), statement) }
                    // An end a `delete` above deletes is still that shape, as a title's is.
                    let gone = resolution.match.shapes.filter { deletedShapes.contains($0.id) && $0.board == target.board }
                    if let record = here.first ?? gone.first.flatMap({ editor.file.record($0.id) }) {
                        return (.here(record.id, item: nil), path.written)
                    }
                    if resolution.elsewhere.count > 1 {
                        let several = resolution.elsewhere
                        throw DrawError(statement, .ambiguousTitle, "\(path.written) is on \(Set(several.map(\.board)).count) boards: \(fileNames?.listing(several) ?? "")",
                                        hint: fileNames?.pathHint(for: several) ?? "write the #id of the one you mean, which a query's row gives")
                    }
                    if let place = resolution.elsewhere.first, let record = editor.file.record(place.id) {
                        return (.away(FarShape(record: record, board: place.board)), path.written)
                    }
                    if resolution.deleted { throw nothingToDelete(statement, written) }
                    throw DrawError(statement, .unknownTitle, "there's no shape called \(path.written)", hint: "delete edge takes shapes the file has as the script starts")
                case .title(let text):
                    let title = try folded(text, statement)
                    if let record = try boardShape(called: title, statement) ?? deletes.lazy.compactMap(\.shape).first(where: { names.name(of: $0) == title }) {
                        return (.here(record.id, item: nil), quoted(title))
                    }
                    guard let far = try farShape(called: title, statement) else { throw none(title) }
                    return (.away(far), quoted(title))
                case .id(let text):
                    let id = try shapeID(text, statement), mark = name.written
                    let shape = try fileShape(withID: id, written: mark, statement)
                    let said = self.said(shape.record, written: mark)
                    if shape.board == target.board { return (.here(id, item: nil), said) }
                    if takenBoards.boards(owned: deletedShapes, in: editor.file).contains(shape.board) { throw deletedID(mark, statement, for: "\(Keyword.delete.rawValue) \(Keyword.edge.rawValue) names") }
                    return (.away(FarShape(record: shape.record, board: shape.board)), said)
                }
            }
            let (a, fromSaid) = try end(fromWritten)
            let (b, toSaid) = try end(toWritten)
            if case .away(let far) = a, case .away = b {
                throw severalBoards(said: fromSaid, on: far.board, statement, for: "\(Keyword.delete.rawValue) \(Keyword.edge.rawValue) \(written) names")
            }
            // A row at an end narrows the pair's arrows to those bound to it there (a key out of several between two tables), as
            // `is:` narrows them by type; an end with none takes any.
            func row(_ name: String?, at found: EdgeEndFound, said: String) throws(DrawError) -> PartID? {
                guard let name else { return nil }
                guard case .here(let id, _) = found, let record = target.document[id] else {
                    throw DrawError(statement, .unsupported, "\(said)\(ShapeName.writtenRow(name)) is on another board, and delete edge reaches a row only on its own",
                                    hint: "write delete edge \(fromWritten.written) -> \(toWritten.written), which takes every edge between them")
                }
                return try part(named: name, of: record, said: said, statement)
            }
            let rows = EdgeRows(from: try row(fromRow, at: a, said: fromSaid), to: try row(toRow, at: b, said: toSaid))
            let pairs = eitherWay ? [(a.id, b.id), (b.id, a.id)] : [(a.id, b.id)]
            if let earlier = edgeDeletes.first(where: { other in
                if let identity, let theirs = other.identity, identity.differs(from: theirs) { return false }
                // Two rows' keys between one pair are two edges.
                if (other.rows.from != nil || rows.from != nil || other.rows.to != nil || rows.to != nil), other.rows != rows { return false }
                return pairs.contains { $0 == (other.from, other.to) || other.eitherWay && $0 == (other.to, other.from) }
            }) {
                throw DrawError(statement, .duplicate, "delete edge \(written) is written twice, here and on line \(earlier.line)", hint: "keep one")
            }
            edgeDeletes.append((a.id, b.id, eitherWay, statement.line, identity, rows))
            // Drawn straight between them, or, as an edge to a shape on another board is, into a
            // stand-in for it beside the other. With an identity, those that hold what it writes; with a row at an end, those bound
            // to it there.
            let found = edgeMatches(from: a.id, to: b.id, bothHeads: eitherWay, among: connections, in: target.document, identity: identity).filter { match in
                guard rows.from != nil || rows.to != nil else { return true }
                let held = registry.edges(of: match.connection.record).first(where: \.isConnection)?.parts ?? .none
                let parts = match.reversed ? (from: held.target, to: held.source) : (from: held.source, to: held.target)
                return (rows.from == nil || rows.from == parts.from) && (rows.to == nil || rows.to == parts.to)
            }
            guard !found.isEmpty else { throw nothingToDelete(statement, written) }
            for match in found {
                try writable(match.connection.record, statement, "one of the connections delete edge \(written) removes", so: "it can't be deleted")
            }
            let fresh = found.filter { !deleted.contains($0.connection.record.id) }
            deletes.append(DeleteItem(statement: statement, shape: nil, connections: fresh.map(\.connection)))
            deleted.formUnion(fresh.map(\.connection.record.id))
            let said = "\(Keyword.delete.rawValue) \(Keyword.edge.rawValue) \(written)"
            for match in fresh { if let standIn = match.standIn { standInsEmptied[standIn.id] = (statement, said) } }
        }
    }

    /// A stand-in a delete took an arrow from (`delete edge`, or `delete "X"` taking X's) goes too, if
    /// that leaves no arrow on it (one bound at both ends, or at one): it stood for a shape for those
    /// arrows alone.
    private mutating func retireEmptiedStandIns() throws(DrawError) {
        guard !standInsEmptied.isEmpty else { return }
        // Those no arrow the run leaves holds, bound or loose.
        let empty: Set<ShapeID> = standIns.map { Set(StandInRoute($0, registry: registry).emptied(by: deleted, in: target.document)) } ?? []
        for (id, emptied) in standInsEmptied.sorted(by: { ($0.value.statement.line, $0.key.description) < ($1.value.statement.line, $1.key.description) }) {
            guard empty.contains(id), let standIn = target.document[id] else { continue }
            try writable(standIn, emptied.statement, "the \(standIn.kind) that \(emptied.written) leaves with no arrow", so: "it can't be deleted")
            deletes.append(DeleteItem(statement: emptied.statement, shape: standIn, connections: []))
            deleted.insert(id)
        }
        // Said once: a later delete (one that names an arrow's type) asks about its own.
        standInsEmptied = [:]
    }

    private func nothingToDelete(_ statement: Statement, _ written: String) -> DrawError {
        DrawError(statement, .nothingToDelete, "nothing is drawn from one to the other of \(written)",
                  hint: "delete edge removes the connections drawn from the first to the second; <-> takes them either way")
    }

    func noEdges(_ statement: Statement) -> DrawError {
        DrawError(statement, .noEdges, "nothing here draws edges", hint: "leave the edges out: this app has no plugin that connects shapes")
    }

    /// Refuses to delete a read-only shape (a locked one, or one in a locked frame): `"East" is
    /// read-only (locked, say), so it can't be deleted`.
    /// The part (row) of `record` called `row` (`PartedShape.parts(of:)`): its name exactly, else folded as a title is, else
    /// refused (`unknown_row`, with the names it's like); a shape of a kind with no rows is refused too.
    func part(named row: String, of record: AnyShapeRecord, said: String, _ statement: Statement) throws(DrawError) -> PartID {
        guard let parts = registry.parts(of: record) else {
            throw DrawError(statement, .unknownRow, "\(said) is \(indefinite(record.kind)), which has no rows", hint: "name a row of a shape that has them, as \"orders\".customer_id")
        }
        let exact = parts.enumerated().filter { $0.element.name == row }
        if exact.count == 1 { return exact[0].element.id }
        if exact.count > 1 {
            let places = exact.map { String($0.offset + 1) }
            throw DrawError(statement, .ambiguousTitle, "\(said) has \(exact.count) rows called \(quoted(row)), the \(listed(places)) from the top",
                            hint: "rename one of them first, so each row has a name of its own")
        }
        let folded = fold(row)
        let alike = parts.filter { fold($0.name) == folded }
        if alike.count == 1 { return alike[0].id }
        let guesses = Suggestions.closest(to: row, among: parts.map(\.name))
        throw DrawError(statement, .unknownRow, "\(said) has no row called \(quoted(row))",
                        hint: guesses.isEmpty ? (parts.isEmpty ? "it has no rows" : "its rows are \(listed(parts.prefix(8).map { quoted($0.name) }))")
                            : "did you mean \(listed(guesses.map { said + ShapeName.writtenRow($0) }, or: true))?")
    }

    private func writable(_ record: AnyShapeRecord, _ statement: Statement, _ subject: String, so consequence: String) throws(DrawError) {
        guard target.isReadOnly(record) else { return }
        throw DrawError(statement, .readOnly, "\(subject) is read-only (locked, say), so \(consequence)",
                        hint: "leave it out of the script, or ask the user to unlock it")
    }

    // MARK: Shapes

    /// A shape statement's kind, and the shape it's about: pass one, which every title needs.
    private mutating func find(_ shape: ShapeStatement, _ statement: Statement) throws(DrawError) {
        let kind = try drawable(shape.word, statement)
        let vocabulary = vocabulary(of: kind)
        var shape = shape
        // Its name: a title (the shape the board has with it, or a new one), a path (the shape there, or a new one made there), or
        // an id (the shape the file has, never a new one).
        var title: String?, idWritten: String?, byID: AnyShapeRecord?, pathKey: ShapePath?, byPath: Placing?, pathSaid: String?
        // A shape a program's run makes, with the id the program picked for it (`DrawOptions.reserved`).
        var madeAs: ShapeID?
        switch shape.name {
        case .title(let written)?:
            title = try folded(written, statement)
        case .path(let written)?:
            let path = try folded(written, statement)
            title = path.last
            pathSaid = path.written
            if measuring {
                // A measure has no board to read a container from: two paths are two shapes, and one is one.
                pathKey = path
            } else {
                // The container goes where `in` names one, so it is put there as `in` puts a shape.
                let placing = try place(path: written, word: shape.word, statement)
                byPath = placing
                shape.name = .title(path.last)
                shape.container = path.container
            }
        case .id(let text)?:
            let id = try shapeID(text, statement), mark = ShapeName.id(text).written
            if options.reserved.contains(id), editor.file.record(id) == nil, namesBeyond?.shape(inFile: id) == nil {
                if let earlier = itemByID[id] {
                    throw DrawError(statement, .duplicate, "\(mark) is written twice, here and on line \(items[earlier].statement.line)",
                                    hint: "say everything about one shape in one statement")
                }
                madeAs = id
                idWritten = mark
                break
            }
            let found = try fileShape(withID: id, written: mark, statement)
            if isDeleted(id, on: found.board) { throw deletedID(mark, statement, for: "\(shape.word) restates") }
            guard found.board == target.board else {
                throw severalBoards(said: mark, on: found.board, statement, for: "\(shape.word) restates")
            }
            byID = found.record
            idWritten = mark
            title = Drawing.title(of: found.record, names: names, naming: naming, registry: registry)
        case nil:
            break
        }
        if let byID, let earlier = itemByID[byID.id] {
            throw DrawError(statement, .duplicate, "\(said(byID, written: idWritten ?? "")) is written twice, here and on line \(items[earlier].statement.line)",
                            hint: "say everything about one shape in one statement")
        }
        var existing: AnyShapeRecord?
        var nearMiss: String?
        var holderID: ShapeID?
        if let byID {
            existing = byID
            if byID.kind != kind {
                let called = said(byID, written: idWritten ?? "")
                throw DrawError(statement, .wrongKind, "\(called) is \(indefinite(byID.kind)) on the board, not \(indefinite(kind))",
                                hint: "to change its kind, delete it and draw a new one in the same script")
            }
        } else if let title {
            if let byPath {
                (existing, holderID) = (byPath.existing, byPath.holder)
            } else if pathKey == nil {
                // `in "X"`: the title is found inside X first, then lying on X's board in no container (restated and moved in), else
                // the shape is new, in X. A lone title is found as the board has it.
                let frame = shape.container.flatMap(frame(named:))
                if let container = shape.container, !measuring {
                    holderID = frame
                    existing = try restated(title, in: container, frame: frame, statement)
                } else {
                    existing = try boardShape(called: title, statement)
                }
            }
            if let existing, let earlier = itemByID[existing.id] {
                throw DrawError(statement, .duplicate, "\(said(existing, written: "")) is written twice, here and on line \(items[earlier].statement.line)",
                                hint: "say everything about one shape in one statement")
            }
            if let existing, existing.kind != kind {
                throw DrawError(statement, .wrongKind, "\(pathSaid ?? quoted(title)) is \(indefinite(existing.kind)) on the board, not \(indefinite(kind))",
                                hint: "to change its kind, delete \(quoted(title)) and draw it again in the same script")
            }
            if existing == nil {
                guard vocabulary.namingProperty != nil else {
                    let why = naming?.isDerived(kind, registry) == true ? "\(indefinite(kind))'s title is worked out from what it is" : "\(indefinite(kind)) has no title"
                    throw DrawError(statement, .untitlable, "\(why), so it can't be called \(quoted(title))",
                                    hint: "leave the title out: \(shape.word) and where it goes")
                }
                // Two statements are one new shape only when they name the same place for it.
                if let earlier = (itemsByTitle[title] ?? []).first(where: { items[$0].existing == nil && items[$0].holderID == holderID && items[$0].pathKey == pathKey }) {
                    throw DrawError(statement, .duplicate, "\(quoted(title)) is written twice, here and on line \(items[earlier].statement.line)",
                                    hint: "say everything about one shape in one statement")
                }
                nearMiss = names.nearMiss(of: title) { $0 != title && isOnBoard($0) }
            }
        }
        let placement = registry.placement(for: kind)!
        let base = existing ?? madeAs.map { placement.shape(at: .zero).copy(as: $0) } ?? placement.shape(at: .zero)
        // A width alone keeps the height, until the kind works out its own at that width (`complete`).
        let had = existing?.box?.size ?? placement.size
        let size = shape.size?.size(height: had.height) ?? had
        // The smallest its shapes are drawn, the kind's tool's and resizing's too (a frame's 96 × 64);
        // a shape restated at the size it is already changes nothing.
        let least = placement.minimumSize
        if let written = shape.size, size.width < least.width || size.height < least.height, size != existing?.box?.size {
            let fitted = Size(width: max(written.width, least.width), height: written.height.map { max($0, least.height) } ?? (size.height < least.height ? least.height : nil))
            let key = LanguageKey.size.rawValue
            throw DrawError(statement, .invalidValue, "\(key): \(written.written) is too small: \(indefinite(kind)) is at least \(Self.written(least))",
                            hint: "write \(key): \(fitted.written), or bigger")
        }
        // A shape named by its id answers to its title only where that title is its alone: two called the same stay `ambiguous_title`.
        if let title, byID == nil || boardShapes(called: title).count < 2 { itemsByTitle[title, default: []].append(items.count) }
        if let existing { itemByID[existing.id] = items.count }
        if let madeAs { itemByID[madeAs] = items.count }
        var item = ShapeItem(statement: statement, shape: shape, kind: kind, title: title, existing: existing, record: base, size: size,
                             room: size, nearMiss: nearMiss, idWritten: idWritten)
        item.exact = options.places[statement.line]
        item.holderID = holderID
        item.pathKey = pathKey
        items.append(item)
    }

    /// The shape `<kind> "T" in "X"` restates: the one called T inside X first (anywhere on X's board for a subboard, anywhere within
    /// X for a frame), failing that one lying on X's board in no container, which is restated and moved into X; none: the shape is
    /// new, and made in X. Two or more where it looks are `ambiguous_title`.
    private func restated(_ title: String, in container: ShapeName, frame: ShapeID?, _ statement: Statement) throws(DrawError) -> AnyShapeRecord? {
        guard let frame else { return try boardShape(called: title, statement) }
        for found in [boardShapes(called: title, inside: frame), looseBoardShapes(called: title)] {
            let records = found.compactMap { target.document[$0] }
            if records.count > 1 { throw ambiguous(quoted(title), records.map(ShapeItem.Found.shape), statement) }
            if let record = records.first { return record }
        }
        return nil
    }

    /// The kind a statement's first word names, if its tool places it: a kind drawn by a gesture
    /// (an edge) or only by plugins isn't drawn here.
    private func drawable(_ word: String, _ statement: Statement) throws(DrawError) -> ShapeKind {
        let kind = ShapeKind(rawValue: word)
        let drawable = drawableKinds
        guard registry.definition(for: kind) != nil else {
            let guess = Suggestions.closest(to: word, among: drawable, limit: 1).first
            var hint = (guess.map { "did you mean \($0)? " } ?? "") + "the kinds drawn here: \(drawable.joined(separator: ", "))"
            if Self.connectionHabits.contains(word), edgeKind != nil {
                hint = "to join two shapes, write edge \"A\" -> \"B\"; " + hint
            } else if Self.habits.contains(word) {
                hint += "; a statement starts with its kind, as in \(guess ?? "<kind>") \"A\""
            }
            throw DrawError(statement, .unknownKind, "there's no kind of shape called \(word)", hint: hint)
        }
        guard registry.placement(for: kind) != nil else {
            let hint = kind == edgeKind ? "to join two shapes, write edge \"A\" -> \"B\""
                : "the kinds drawn here: \(drawable.joined(separator: ", "))"
            throw DrawError(statement, .notPlaceable, "\(indefinite(word)) isn't drawn on its own: \(unplaceable(kind, in: registry))", hint: hint)
        }
        return kind
    }

    /// Words other drawing languages start a shape with.
    private static let habits: Set<String> = ["node", "note", "box", "shape"]
    /// Words other drawing languages start a connection with.
    private static let connectionHabits: Set<String> = ["link", "connect"]

    /// Keys other languages say where a shape is with, and how big: there are no coordinates here.
    private static let coordinateKeys: Set<String> = ["x", "y", "at", "position", "pos"]
    private static let sizeKeys: Set<String> = ["width", "height"]

    /// The kinds a script can draw: those a tool places (but one named like a word of the
    /// language), by name.
    var drawableKinds: [String] {
        registry.kinds.filter { registry.placement(for: $0) != nil && Keyword(rawValue: $0.rawValue) == nil }.map(\.rawValue).sorted()
    }

    mutating func vocabulary(of kind: ShapeKind) -> KindVocabulary {
        if let known = vocabularies[kind] { return known }
        let vocabulary = KindVocabulary(kind, in: registry)
        vocabularies[kind] = vocabulary
        return vocabulary
    }

    /// Pass two, once every title is known: what holds it, the rename, the attributes (and the
    /// styles that give them), and the placements' targets.
    private mutating func complete(_ index: Int) throws(DrawError) {
        try contain(index)
        let item = items[index], statement = item.statement, shape = item.shape
        let vocabulary = vocabulary(of: item.kind)
        let subject = subject(of: item)
        var settings: JSONObject = [:]

        // A board that can't change (a locked subboard's, at any depth) takes no new shape.
        if item.existing == nil, target.isBoardReadOnly {
            throw DrawError(statement, .readOnly, "\(subject) would go on \(boardName), which is read-only (locked, say)",
                            hint: "leave it out of the script, or ask the user to unlock what holds the board")
        }

        // Its title, on a new shape; a new one, on a shape restated. A program's run names its shapes by id, and a title is
        // only what it calls a shape: `title:` gives one a shape it makes, and any shape one another beside it has.
        if options.program, let written = shape.newTitle {
            let new = try folded(written, statement)
            guard let property = vocabulary.namingProperty else {
                throw DrawError(statement, .untitlable, "\(indefinite(item.kind)) can't be given a title, so \(subject) can't be called \(quoted(new))",
                                hint: "leave \(LanguageKey.title.rawValue): out")
            }
            if new != item.title {
                if item.existing != nil { items[index].rename = new }
                settings[property] = .string(new)
            }
        } else if let written = shape.newTitle {
            guard let existing = item.existing else {
                throw DrawError(statement, .unsupported, "\(subject) is new, and \(LanguageKey.title.rawValue): renames a shape",
                                hint: "the title goes after the kind, in quotes: \(shape.word) \(quoted(written))")
            }
            let new = try folded(written, statement)
            guard let property = vocabulary.namingProperty else {
                throw DrawError(statement, .untitlable, "\(indefinite(item.kind)) can't be given a title, so \(subject) can't be renamed",
                                hint: "leave \(LanguageKey.title.rawValue): out")
            }
            if new != item.title {
                try claim(new, for: existing, statement, subject: subject)
                items[index].rename = new
                settings[property] = .string(new)
            }
        } else if item.existing == nil, let title = item.title, let property = vocabulary.namingProperty {
            settings[property] = .string(title)
        }

        // Its attributes, its own and its styles'.
        for attribute in shape.attributes {
            let key = attribute.key
            guard vocabulary.properties[key] != nil, !vocabulary.isReadOnly(key), !vocabulary.isUnlisted(key) else {
                if attribute.fromStyle != nil { continue }
                if Self.coordinateKeys.contains(key) {
                    throw DrawError(statement, .unsupported, "\(key): would say where \(subject) is, and there are no coordinates here",
                                    hint: "say where it goes with a placement: right of \"A\", below board, inside view top-left")
                }
                if Self.sizeKeys.contains(key) {
                    let size = LanguageKey.size.rawValue
                    throw DrawError(statement, .unsupported, "\(key): would say how big \(subject) is, and here that's \(size):",
                                    hint: "\(size): <width>x<height>, as \(size): 300x200, or a width alone, as \(size): 300x")
                }
                throw unknownAttribute(key, of: item, vocabulary)
            }
            if key == vocabulary.namingProperty {
                throw DrawError(statement, .unsupported, "\(key): is what \(subject) is called",
                                hint: item.existing == nil ? "the title goes after the kind, in quotes: \(shape.word) \"…\""
                                          : "rename it with \(LanguageKey.title.rawValue): \"…\"")
            }
            if vocabulary.coordinates.contains(key) {
                throw DrawError(statement, .unsupported, "\(key): says where \(subject) is, and there are no coordinates here",
                                hint: "say where it goes with a placement, and how big with \(LanguageKey.size.rawValue):")
            }
            let from = attribute.fromStyle.map { " (from style \($0))" } ?? ""
            let value: JSONValue
            do throws(ValueRefusal) {
                value = try vocabulary.value(of: attribute)
                try fits(value, key, item.kind, vocabulary)
                try checkQuery(value, key, vocabulary)
            } catch {
                throw DrawError(statement, .invalidValue, "\(subject): \(error.message)\(from)", hint: error.hint)
            }
            let joined: (written: JSONValue, set: JSONValue)
            do throws(DrawError) {
                let texts = try writtenTexts(value, of: key, vocabulary, owner: item.record.id, prefix: "\(subject): \(key)", suffix: from, statement)
                // A property whose owner says how a value joins what the shape holds (Types' `fieldValues`) is
                // set to the join, so a statement names only what it changes.
                joined = try writtenValue(texts, of: key, vocabulary, owner: item.record.id, joining: .some(item.existing?.propertiesJSON?[key]),
                                          prefix: "\(subject): \(key)", suffix: from, statement)
            } catch {
                // Measuring says a name it can't find, and measures the shape without it, or with the value as written when the
                // kind takes that.
                guard measuring, error.fromNameLookup else { throw error }
                let asWritten = (try? registry.shape(item.record, setting: [key: value])) != nil
                measureWarnings.append((statement.line, error.message + (asWritten ? "; measured as written" : "; measured without it")))
                if asWritten { settings[key] = value }
                continue
            }
            settings[key] = joined.set
            if registry.drawValueWriters[key] != nil { items[index].written[key] = joined.written }
        }
        for name in shape.styles {
            guard let style = script.styles.first(where: { $0.name == name }) else { continue }
            let gives = style.attributes.contains { LanguageKey(rawValue: $0.key) != nil || vocabulary.isAttribute($0.key) }
            if !gives {
                throw DrawError(statement, .unknownAttribute, "\(subject) is \(indefinite(item.kind)), and style \(name) gives it nothing it takes",
                                hint: "\(indefinite(item.kind)) takes \(vocabulary.everything.joined(separator: ", "))")
            }
        }
        // What a restated shape already has isn't a change, though it's written without what reading
        // it makes afresh (the id of an item in a list): a script run again changes nothing.
        if let existing = item.existing {
            let held = existing.propertiesJSON
            settings = settings.filter { key, value in
                // A joined value that comes to nothing, over a shape that holds nothing, changes nothing.
                if value == .null, registry.drawValueWriters[key] != nil, held?[key] == nil { return false }
                return !Self.alreadyHas(existing, key, value, now: held?[key], in: registry)
            }
        }
        // Every shape a script makes is built by the registry, as the kind's schema reads it. Given a
        // width alone (`size: 300x`), it's built at that width, and what the kind works out from the
        // rest (a note's height, from its text) is worked out there, whether anything's set or not.
        var built = item.record
        let widthAlone = shape.size.flatMap { $0.height == nil ? $0.width : nil }
        if let widthAlone, var box = built.box {
            box.size.width = widthAlone
            built.box = box
            built = registry.derived(built)
        }
        if !settings.isEmpty || item.existing == nil { built = try record(built, setting: settings, item, vocabulary) }
        // A size written whole (`size: 300x200`) is given as a resize gives one: as the kind takes a frame
        // (`registry.sized`; a note keeps the height as the least it is, and is as tall as its words past it).
        let sizedWhole = shape.size?.height != nil
        if sizedWhole, let box = built.box {
            built = registry.sized(built, to: CGRect(origin: box.origin, size: item.size), giving: .both, in: target.shapes)
        }
        items[index].record = built
        try references(of: built, item)
        // A size the kind works out from what was set (a note's height, from its text) is
        // the one it's placed at, unless the statement says one; with a width alone, the height it works
        // out at that width (any other kind's height as it was); written whole, the size the kind took.
        if let widthAlone, let height = built.box?.height {
            items[index].size = CGSize(width: widthAlone, height: height)
        } else if sizedWhole, let size = built.box?.size {
            items[index].size = size
        } else if shape.size == nil, let before = item.record.box?.size, let after = built.box?.size, after != before {
            items[index].size = after
        }

        if let title = item.title, let existing = item.existing, items[index].rename == nil, let box = existing.box {
            var sized = items[index].record
            sized.box = CGRect(origin: box.origin, size: items[index].size)
            if vocabulary.namingProperty == nil {
                // A title only worked out (`title { … }`) is renamed by changing
                // what it's worked out from: said as a rename, and held to what a rename is.
                if let now = try renamed(sized, title, item) {
                    try claim(now, for: existing, statement, subject: subject)
                    items[index].rename = now
                }
            } else {
                // One a kind works out for the shapes nobody named (from its size, say) mustn't
                // change under it.
                try keepsName(sized, title, item)
            }
        }

        // Where it goes: what each placement names.
        try resolveTargets(index)
    }

    /// What each of an item's placements names, placement by placement (`ShapeItem.targets`): a shape the script draws or
    /// restates, one on the board the run draws on, `board`, `view` or `origin`. A shape statement's, and the placements an edge writes
    /// for the stand-in it makes (`addStandIn`).
    mutating func resolveTargets(_ index: Int) throws(DrawError) {
        let item = items[index], statement = item.statement
        let subject = subject(of: item)
        var targets: [[ShapeItem.Found]] = []
        for clause in item.shape.clauses {
            var found: [ShapeItem.Found] = []
            for target in clause.targets {
                switch target.box {
                case .title(let written):
                    let title = try folded(written, statement)
                    if title == item.title {
                        throw DrawError(statement, .circular, "\(subject) is placed against itself (\(clause.written))",
                                        hint: "place it against another shape")
                    }
                    guard let target = try find(title, statement, for: "\(subject) is placed against", mine: item.title, inside: item.holder?.id) else { throw skip() }
                    found.append(target)
                case .path(let written):
                    guard let target = try find(path: written, statement, for: "\(subject) is placed against") else { throw skip() }
                    if case .item(let other) = target, other == index {
                        throw DrawError(statement, .circular, "\(subject) is placed against itself (\(clause.written))", hint: "place it against another shape")
                    }
                    if case .shape(let record) = target, record.id == item.existing?.id {
                        throw DrawError(statement, .circular, "\(subject) is placed against itself (\(clause.written))", hint: "place it against another shape")
                    }
                    found.append(target)
                case .id(let text):
                    let id = try shapeID(text, statement), mark = ShapeName.id(text).written
                    if id == item.existing?.id {
                        throw DrawError(statement, .circular, "\(subject) is placed against itself (\(clause.written))",
                                        hint: "place it against another shape")
                    }
                    guard let target = try find(id: id, written: mark, statement, for: "\(subject) is placed against") else { throw skip() }
                    found.append(target)
                case .board:
                    found.append(.board)
                case .view:
                    guard view != nil else {
                        throw DrawError(statement, .noView, "\(subject) is \(clause.written), and the board isn't in a window",
                                        hint: "place it against a shape, or leave it unplaced to draw it where the view would be")
                    }
                    found.append(.view)
                case .origin:
                    found.append(.origin)
                }
            }
            targets.append(found)
        }
        items[index].targets = targets
    }

    /// What holds a statement's shape, when `in "F"` names a shape that holds others on its own
    /// board (a frame): the shape goes within F, and in it, as its placements say; with none, and not
    /// in F already (where it stays), against F's top-left, 40 in, as `inside "F" top-left` places
    /// it. F must be one the script neither deletes nor is (or holds), and writable: a read-only
    /// container (a locked frame) takes nothing, nor does a subboard `in` names whose board is
    /// read-only (it, or a subboard above it, locked). The stand-in an edge puts `in "F"` is held so too
    /// (`addStandIn`).
    mutating func contain(_ index: Int) throws(DrawError) {
        let item = items[index]
        guard let name = item.shape.container, let fileNames else { return }
        // What the shape is called in a message, the box a placement names it by, and what it is.
        let said: String, box: Target.Box, found: FileNames.Container
        switch name {
        case .title(let written):
            guard let title = fold(written) else { return }
            (said, box, found) = (quoted(title), .title(written), fileNames.container(called: title))
        case .id(let text):
            let id = try shapeID(text, item.statement)
            (said, box, found) = (name.written, .id(text), fileNames.container(withID: id))
        case .path(let written):
            let path = try folded(written, item.statement)
            (said, box, found) = (path.written, .path(written), fileNames.container(path: path, board: target.board))
        }
        if case .board = found, target.isBoardReadOnly { throw readOnlyHolder(said, item.statement) }
        guard case .shape(let id, _) = found else { return }
        let statement = item.statement, subject = subject(of: item)
        guard let holder = target.document[id] else {
            throw DrawError(statement, .internal, "\(said) isn't on the board \(subject) is drawn on")
        }
        if deletedShapes.contains(id) {
            throw DrawError(statement, name.id == nil ? .unknownTitle : .unknownID, "\(subject) is in \(said), which this script deletes",
                            hint: name.id == nil ? "draw \(said) again after deleting it, or leave in \(said) out" : "leave in \(said) out")
        }
        let kinds = registry.containingKinds
        if let existing = item.existing, existing.id == id || target.document.containers(of: id, containingKinds: kinds).contains(existing.id) {
            throw DrawError(statement, .circular,
                            existing.id == id ? "\(subject) is in itself" : "\(subject) holds \(said), so it can't be in it",
                            hint: "name another shape to hold it")
        }
        if target.isReadOnly(holder) { throw readOnlyHolder(said, statement) }
        items[index].holder = holder
        let isIn = item.existing.map { target.document.containers(of: $0.id, containingKinds: kinds).contains(id) } ?? false
        if item.shape.clauses.isEmpty, !isIn {
            items[index].shape.clauses.append(Clause(relation: .inside, targets: [Target(box, part: .topLeft)], written: "in \(said)"))
        }
    }

    /// `in "F"` names a shape that takes nothing: read-only (locked, say), a frame, or a subboard
    /// whose board is.
    private func readOnlyHolder(_ said: String, _ statement: Statement) -> DrawError {
        DrawError(statement, .readOnly, "\(said) is read-only (locked, say), so nothing goes in it",
                  hint: "leave in \(said) out, or ask the user to unlock it")
    }

    /// The shape with its attributes set, or which one it can't take.
    private func record(_ base: AnyShapeRecord, setting settings: JSONObject, _ item: ShapeItem,
                        _ vocabulary: KindVocabulary) throws(DrawError) -> AnyShapeRecord {
        do throws(ShapePropertiesError) {
            return try registry.shape(base, setting: settings)
        } catch {
            // Which one: each alone.
            for key in settings.keys.sorted() {
                do throws(ShapePropertiesError) {
                    _ = try registry.shape(base, setting: [key: settings[key]!])
                } catch {
                    let written = item.shape.attributes.first { $0.key == key }?.value.written ?? "\(LanguageKey.title.rawValue)"
                    throw DrawError(item.statement, .invalidValue, "\(subject(of: item)): \(key): \(written) can't be read: \(error)",
                                    hint: "\(key): takes \(vocabulary.compactType(of: key))")
                }
            }
            throw DrawError(item.statement, .invalidValue, "\(subject(of: item)) can't have those attributes together: \(error)")
        }
    }

    /// Refuses JSON (an object or a list) that its property's schema says has a member it hasn't, or
    /// a value of the wrong type, anywhere inside: reading it would drop the member, or the whole
    /// value, without a word. Its bounds aren't refused: a shape past one is drawn, and warned about.
    private func fits(_ value: JSONValue, _ key: String, _ kind: ShapeKind, _ vocabulary: KindVocabulary) throws(ValueRefusal) {
        switch value {
        case .object, .array: break
        default: return
        }
        let violations = registry.schemaViolations(of: [key: value], kind: kind).filter { violation in
            guard violation.path.first == .member(key) else { return false }
            switch violation.keyword {
            case "additionalProperties": return true
            // Null inside reads as the member's default, as it does for a whole property.
            case "type": return Self.value(at: violation.path.dropFirst(), in: value) != .null
            default: return false
            }
        }
        guard let violation = violations.first else { return }
        let takes = "\(key): takes \(vocabulary.compactType(of: key))"
        guard violation.keyword == "additionalProperties", case .member(let member)? = violation.path.last else {
            var message = violation.message
            if message.hasSuffix(".") { message.removeLast() }
            throw ValueRefusal(message: "\(key): \(message)", hint: takes)
        }
        let inside = violation.path.dropFirst().dropLast()
        let place = inside.isEmpty ? key : inside.map { step in
            switch step {
            case .member(let name): name
            case .element(let index): "item \(index + 1)"
            }
        }.joined(separator: " › ")
        let members = vocabulary.members(of: key, at: inside) ?? []
        let guess = Suggestions.closest(to: member, among: members, limit: 1).first
        throw ValueRefusal(message: "\(key): \(member) isn't a member of \(place)" + (members.isEmpty ? "" : " (it has \(listed(members)))"),
                           hint: (guess.map { "did you mean \($0)? " } ?? "") + takes)
    }

    /// The part of a JSON value a path leads to.
    static func value(at path: some Collection<JSONPathComponent>, in value: JSONValue) -> JSONValue? {
        var value = value
        for step in path {
            switch (step, value) {
            case let (.member(name), .object(members)):
                guard let member = members[name] else { return nil }
                value = member
            case let (.element(index), .array(elements)):
                guard elements.indices.contains(index) else { return nil }
                value = elements[index]
            default:
                return nil
            }
        }
        return value
    }

    /// Whether setting `key` to `value` would leave the shape as it is: what the value reads as is
    /// what the shape has, but for what reading it makes afresh each time (the id an item in a list
    /// written without one gets), found by reading it twice.
    static func alreadyHas(_ record: AnyShapeRecord, _ key: String, _ value: JSONValue, in registry: Registry) -> Bool {
        alreadyHas(record, key, value, now: record.propertiesJSON?[key], in: registry)
    }

    /// `alreadyHas`, given what the shape holds of `key` now (`now`, nil for nothing). A value written as the shape holds it is had
    /// at once: a value read from a record is in the form the kind writes it, so reading it again gives it back, and the shape
    /// need not be built twice to see so (a note's built, its height worked out from its text, each time).
    static func alreadyHas(_ record: AnyShapeRecord, _ key: String, _ value: JSONValue, now: JSONValue?, in registry: Registry) -> Bool {
        guard let now else { return false }
        if now == value { return true }
        guard let once = try? registry.shape(record, setting: [key: value]).propertiesJSON?[key],
              let twice = try? registry.shape(record, setting: [key: value]).propertiesJSON?[key] else { return false }
        return matches(once, now, fresh: twice)
    }

    /// Whether `a` is `b` wherever `a` agrees with `fresh`, another reading of what `a` was read
    /// from: where the two differ, it's made afresh, and anything matches it.
    static func matches(_ a: JSONValue, _ b: JSONValue, fresh: JSONValue) -> Bool {
        if a == b { return true }
        switch (a, b, fresh) {
        case let (.object(a), .object(b), .object(fresh)):
            return Set(a.keys) == Set(b.keys) && a.allSatisfy { key, value in fresh[key].map { matches(value, b[key]!, fresh: $0) } ?? false }
        case let (.array(a), .array(b), .array(fresh)):
            return a.count == b.count && a.count == fresh.count && a.indices.allSatisfy { matches(a[$0], b[$0], fresh: fresh[$0]) }
        default:
            return a != fresh
        }
    }

    /// Refuses a shape bound to shapes that aren't on the board as the script leaves it (an arrow's
    /// ends, `ShapeReferencing`): it would stay bound to one, and nothing would ever let go of it;
    /// one on another board of the file is no better. What it only names (a mention, `ShapeNaming`)
    /// may be anywhere in the file, or gone: that's said, not refused (`namingWarnings`).
    private func references(of record: AnyShapeRecord, _ item: ShapeItem) throws(DrawError) {
        let away = record.boundShapes(in: target.shapes).filter { target.document[$0] == nil || deleted.contains($0) }
        guard let first = away.first else { return }
        let elsewhere = target.document[first] == nil && editor.file.record(first) != nil
        throw DrawError(item.statement, .invalidValue,
                        "\(subject(of: item)) is bound to a shape \(elsewhere ? "on another board of the file" : "that isn't on this board")",
                        hint: "a shape can be bound only to shapes on its own board")
    }

    /// Refuses a new title for a restated shape that another shape directly beside it has, or will have: one the script draws,
    /// renames to it, or the board has, in the same frame, or on the board in no frame. A shape in another frame, or on another
    /// board, may have the title: a path names each.
    private func claim(_ new: String, for existing: AnyShapeRecord, _ statement: Statement, subject: String) throws(DrawError) -> Void {
        let kinds = registry.containingKinds
        let home = target.document.container(of: existing.id, containingKinds: kinds)
        // The frame a statement's shape is in, or goes in.
        func parent(of item: ShapeItem) -> ShapeID? {
            item.existing.map { target.document.container(of: $0.id, containingKinds: kinds) } ?? item.holderID
        }
        if let other = (itemsByTitle[new] ?? []).first(where: { items[$0].existing?.id != existing.id && parent(of: items[$0]) == home }) {
            throw DrawError(statement, .duplicate, "\(quoted(new)) is taken: line \(items[other].statement.line) is about it",
                            hint: "give \(subject) a title of its own")
        }
        if let other = items.firstIndex(where: { $0.rename == new && parent(of: $0) == home }) {
            throw DrawError(statement, .duplicate, "\(quoted(new)) is written twice, here and on line \(items[other].statement.line)",
                            hint: "give each shape a title of its own")
        }
        if boardShapes(called: new).contains(where: { $0 != existing.id && target.document.container(of: $0, containingKinds: kinds) == home }) {
            throw DrawError(statement, .duplicate, "\(quoted(new)) is taken: \(home == nil ? "the board" : "the frame") has a shape called that",
                            hint: "give \(subject) a title of its own")
        }
    }

    /// The title a restated shape of a kind whose titles are only worked out (`title { … }`, from
    /// its schema's "title") has once changed, if that's another; refused if it has none, as a
    /// script can't take a title away.
    private func renamed(_ record: AnyShapeRecord, _ title: String, _ item: ShapeItem) throws(DrawError) -> String? {
        guard let naming else { return nil }
        guard let now = naming.name(record, registry) else {
            throw DrawError(item.statement, .renames, "this would leave \(quoted(title)) without a title",
                            hint: "its title is worked out from what it is: keep what it's worked out from giving it one")
        }
        return now == title ? nil : now
    }

    /// Refuses a change that would change a restated shape's title (one its kind works out).
    func keepsName(_ record: AnyShapeRecord, _ title: String, _ item: ShapeItem) throws(DrawError) {
        guard let naming, let now = naming.name(record, registry), now != title else { return }
        let size = item.shape.size.map { "\(LanguageKey.size.rawValue): \($0.written)" }
        throw DrawError(item.statement, .renames, "\(size ?? "this") would rename \(quoted(title)) to \(quoted(now))",
                        hint: "its title is worked out from what it is: give it one with \(LanguageKey.title.rawValue): \"…\" first, or leave it as it is")
    }

    static func written(_ size: CGSize) -> String {
        "\(KindVocabulary.number(size.width))x\(KindVocabulary.number(size.height))"
    }

    private func unknownAttribute(_ key: String, of item: ShapeItem, _ vocabulary: KindVocabulary) -> DrawError {
        let takes = vocabulary.everything
        var hints: [String] = []
        if let guess = Suggestions.closest(to: key, among: takes, limit: 1).first { hints.append("did you mean \(guess)?") }
        hints.append("\(indefinite(item.kind)) takes \(takes.map { "\($0):" }.joined(separator: ", "))")
        let others = registry.kinds.filter { $0 != item.kind && registry.placement(for: $0) != nil }
            .filter { KindVocabulary($0, in: registry).isAttribute(key) }.map(\.rawValue).sorted()
        if !others.isEmpty { hints.append("\(key): belongs to \(listed(others))") }
        let who = item.title.map { "\(quoted($0)) is \(indefinite(item.kind)) and" } ?? "\(subject(of: item))"
        return DrawError(item.statement, .unknownAttribute, "\(who) has \(key):, which isn't one of \(indefinite(item.kind))'s attributes",
                         hint: hints.joined(separator: "; "))
    }

    // MARK: Edges

    /// The edges a shape statement's values imply, from the shape it draws, as edge statements: those its value writers say
    /// (`DrawValueWriting.edges`) and, for a person's put, those the put says its statement implies (`DrawOptions.implied`, a
    /// table's keys): none for a statement that couldn't be resolved, or one whose values imply none. A shape with no name can't
    /// be an edge's end, so a value of one that implies an edge is refused.
    private func impliedEdges(of shape: ShapeStatement, _ statement: Statement) throws(DrawError) -> [(EdgeStatement, DrawImpliedEdge)] {
        if let title = shape.title, unresolved.contains(fold(title) ?? title) { return [] }
        guard let lookup = textWriter?.lookup else { return [] }
        let writers = registry.drawValueWriters
        var implied: [(EdgeStatement, DrawImpliedEdge)] = []
        // What each value's writer says it implies, then what a put says its statement implies (`DrawOptions.implied`).
        var said: [(key: String, edges: [DrawImpliedEdge])] = []
        for attribute in shape.attributes {
            guard let writer = writers[attribute.key], writer.impliesEdges, case .quoted(let text) = attribute.value else { continue }
            do throws(DrawError) {
                said.append((attribute.key, try writer.edges(.string(text), DrawTextContext(registry: registry, schema: [:], owner: nil, lookup: lookup))))
            } catch {
                throw error.said(error.message, on: statement)
            }
        }
        if let put = options.implied[statement.line] { said.append(("the put", put)) }
        for (key, found) in said {
            guard !found.isEmpty else { continue }
            guard let name = shape.name else {
                throw DrawError(statement, .unsupported, "\(key): draws an edge from the \(shape.word) this line draws, and it has no title to start from",
                                hint: "give the \(shape.word) a title: \(shape.word) \"orders\" \(key): …")
            }
            for edge in found {
                // The far shape as a text finds it, by its id where the run draws it or the file has it (a program's run keys its shapes, and
                // a table it draws has no title to find it by yet); a title that finds none is left to the edge to refuse.
                let found = try? lookup.shape(called: edge.to, admitting: { _, _ in nil })
                let far = found.flatMap { itemByID[$0.id] != nil || editor.file.record($0.id) != nil ? ShapeName.id($0.id.description) : nil } ?? .title(edge.to)
                var made = EdgeStatement(from: name, to: far,
                                         attributes: edge.attributes.sorted { $0.key < $1.key }.map { Attribute(key: $0.key, value: .word($0.value)) })
                made.fromRow = edge.fromRow
                made.toRow = edge.toRow
                implied.append((made, edge))
            }
        }
        return implied
    }

    /// An edge statement resolved: its ends, their rows, its attributes, the stand-in it goes through. `implied`: an edge a value
    /// implies (`impliedEdges`), which an edge the script writes between the same rows is already, and is then dropped.
    private mutating func resolve(_ edge: EdgeStatement, _ statement: Statement, implied: DrawImpliedEdge? = nil) throws(DrawError) {
        guard let edging, let edgeKind else { throw noEdges(statement) }
        let written = "\(Keyword.edge.rawValue) \(edge.written)"
        // An end is a shape the script draws, or the board has, or, elsewhere in the file, the shape
        // there: the edge then goes through a stand-in beside the other end (`DrawStandIns.swift`). Named by its title
        // or, for a shape that has none, by its id.
        func end(_ name: ShapeName) throws(DrawError) -> (found: EdgeEndFound, name: EndName) {
            switch name {
            case .id(let text):
                return try endFound(id: try shapeID(text, statement), written: name.written, statement)
            case .path(let text):
                return try endFound(path: text, statement, written: written)
            case .title(let text):
                let title = try folded(text, statement)
                let drawn = itemsByTitle[title] ?? []
                if drawn.count > 1 { throw ambiguous(quoted(title), drawn.map(ShapeItem.Found.item), statement) }
                if let index = drawn.first { return (.here(items[index].record.id, item: index), EndName(title: title)) }
                if unresolved.contains(title) { throw skip() }
                // A measure reads the ends the open file has wherever they are, and lays the arrow out straight: it draws no pill.
                if measuring { return (.here(try measuredEnd(title, statement), item: nil), EndName(title: title)) }
                if let record = try boardShape(called: title, statement) { return (.here(record.id, item: nil), EndName(title: title)) }
                if names.ids[title] == nil, let far = try farShape(called: title, statement) { return (.away(far), EndName(title: title)) }
                throw notFound(title, statement, for: "\(written) is drawn to", elsewhere: false)
            }
        }
        let (fromFound, fromName) = try end(edge.from), (toFound, toName) = try end(edge.to)
        let from = fromFound.id, to = toFound.id
        // A row an end names is a part of the shape there: of the shape as the script draws it, else as the board has it.
        func part(_ row: String?, at found: EdgeEndFound, named: EndName) throws(DrawError) -> PartID? {
            guard let row else { return nil }
            let record: AnyShapeRecord?
            switch found {
            case .here(let id, let item): record = item.map { items[$0].record } ?? target.document[id]
            case .away:
                throw DrawError(statement, .unsupported, "\(named.said)\(ShapeName.writtenRow(row)) is on another board, and an edge reaches a row only on its own",
                                hint: "draw the edge on the board \(named.said) is on, or to \(named.said) as a whole")
            }
            guard let record else { throw DrawError(statement, .internal, "\(written) came out naming a shape that isn't on the board") }
            let id = try self.part(named: row, of: record, said: named.said, statement)
            // Deletes are read before edges, so the one that takes the row may be on a later line.
            if let line = rowDeleteLines[PartAddress(record.id, part: id)] {
                throw DrawError(statement, .unknownRow, "\(named.said)\(ShapeName.writtenRow(row)) is deleted on line \(line)",
                                hint: "leave the delete out, or the edge")
            }
            return id
        }
        let fromPart = try part(edge.fromRow, at: fromFound, named: fromName), toPart = try part(edge.toRow, at: toFound, named: toName)
        let via = try edge.via.map { word throws(DrawError) in try standInKind(named: word, statement, written: written) }
        // The edge maker's attributes (a channel), then its kind's own, as a shape's are.
        var attributes: [String: String] = [:], settings: JSONObject = [:]
        let connector = vocabulary(of: edgeKind)
        for attribute in edge.attributes {
            let key = attribute.key
            if edging.attributes.contains(key) {
                attributes[key] = attribute.value.text
                continue
            }
            guard connector.isAttribute(key) else {
                if connector.coordinates.contains(key) {
                    throw DrawError(statement, .unsupported, "\(key): says where \(written) is, and an edge goes where its ends are",
                                    hint: "leave \(key): out")
                }
                let takes = (EdgeKey.allCases.map(\.rawValue) + edging.attributes + connector.attributes).reduce(into: [String]()) { all, key in
                    if !all.contains(key) { all.append(key) }
                }
                let guess = Suggestions.closest(to: key, among: takes, limit: 1).first
                throw DrawError(statement, .unknownAttribute, "an edge has no \(key): attribute",
                                hint: (guess.map { "did you mean \($0)? " } ?? "") + "an edge takes \(takes.map { "\($0):" }.joined(separator: ", "))")
            }
            settings[key] = try edgeValue(attribute, connector, written: written, statement)
        }
        let identity = identityKeys(connector).flatMap { EdgeIdentity(keys: $0, settings: settings) }
        if let implied, let replaced = implied.replacesType, let fromPart, case .here = fromFound {
            try retireOtherEdges(from: from, row: fromPart, keeping: (to, toPart), type: replaced, statement, written: written)
        }
        let pairs = edge.bothHeads ? [(from, to), (to, from)] : [(from, to)]
        // The first earlier edge that runs between the same pair of shapes, unless the two say which arrow they are about, and differently.
        let sameEnds = pairs.flatMap { edgesByEnds[EdgeEnds(from: $0.0, to: $0.1)] ?? [] }.sorted()
        if let place = sameEnds.first(where: { place in
            if let identity, let theirIdentity = edges[place].identity, identity.differs(from: theirIdentity) { return false }
            // Two keys between one pair of tables are two edges when they join other rows.
            let other = edges[place]
            let same = other.from == from ? (other.fromPart, other.toPart) == (fromPart, toPart) : (other.fromPart, other.toPart) == (toPart, fromPart)
            return same
        }) {
            if implied != nil { return }
            throw DrawError(statement, .duplicate, "\(written) is written twice, here and on line \(edges[place].statement.line)",
                            hint: "say everything about one edge in one statement")
        }
        var item = EdgeItem(statement: statement, edge: edge, fromPart: fromPart, toPart: toPart, from: from, to: to, fromName: fromName,
                            toName: toName, attributes: attributes, settings: settings, identity: identity)
        if !measuring {
            item.standIn = try routeEdge(edge, statement, written: written, from: fromFound, to: toFound, fromName: fromName, toName: toName, via: via,
                                         identity: identity)
        }
        for (from, to) in edge.bothHeads ? [(from, to), (to, from)] : [(from, to)] { edgesByEnds[EdgeEnds(from: from, to: to), default: []].append(edges.count) }
        edges.append(item)
    }

    /// The edges of `type` the board has from `row` of `from` to anywhere but `keeping`, deleted by the statement of an
    /// edge a value implies that re-aims them: a column has the one key its line says. One the script writes itself stays.
    private mutating func retireOtherEdges(from: ShapeID, row: PartID, keeping: (shape: ShapeID, part: PartID?), type: String,
                                           _ statement: Statement, written: String) throws(DrawError) {
        var gone: [BoardConnection] = []
        for connection in boardConnections() where connection.from == from && !deleted.contains(connection.record.id) {
            guard let held = registry.edges(of: connection.record).first(where: \.isConnection), held.parts.source == row else { continue }
            if held.type.rawValue != type { continue }
            if connection.to == keeping.shape, held.parts.target == keeping.part { continue }
            if edges.contains(where: { $0.from == from && $0.fromPart == row && $0.to == connection.to && $0.toPart == held.parts.target }) { continue }
            try writable(connection.record, statement, "the edge from this row that \(written) re-aims", so: "it can't be re-aimed")
            gone.append(connection)
        }
        guard !gone.isEmpty else { return }
        deletes.append(DeleteItem(statement: statement, shape: nil, connections: gone))
        deleted.formUnion(gone.map(\.record.id))
    }

    /// The shape an edge's end names in a measure: one the open file has, on any board (found as a text names a shape).
    private func measuredEnd(_ title: String, _ statement: Statement) throws(DrawError) -> ShapeID {
        guard let lookup = textWriter?.lookup else {
            var missing = DrawError(statement, .unknownTitle, "there's no shape called \(quoted(title))")
            missing.fromNameLookup = true
            throw missing
        }
        do throws(DrawError) {
            return try lookup.shape(called: title, admitting: { _, _ in nil }).id
        } catch {
            guard error.reason != Self.skipped else { throw error }
            throw error.said(error.message, on: statement)
        }
    }

    /// An attribute of the edge kind, read by its schema and written as a statement's value is: joined
    /// with what the arrow holds when it is made (`DrawCommit`).
    private mutating func edgeValue(_ attribute: Attribute, _ connector: KindVocabulary, written: String,
                                    _ statement: Statement) throws(DrawError) -> JSONValue {
        guard let edgeKind else { throw noEdges(statement) }
        let key = attribute.key, value: JSONValue
        do throws(ValueRefusal) {
            value = try connector.value(of: attribute)
            try fits(value, key, edgeKind, connector)
        } catch {
            throw DrawError(statement, .invalidValue, "\(written): \(error.message)", hint: error.hint)
        }
        let texts = try writtenTexts(value, of: key, connector, prefix: "\(written): \(key)", statement)
        return try writtenValue(texts, of: key, connector, owner: nil, joining: nil, prefix: "\(written): \(key)", statement).written
    }

    /// The identity keys (`DrawEdgeIdentities`) that the edge kind has as properties (one it lacks,
    /// because no plugin gave it to the kind in this app, tells nothing apart): nil when it has none,
    /// so a statement is about the pair.
    func identityKeys(_ connector: KindVocabulary) -> [String]? {
        let keys = edgeIdentityKeys.filter(connector.isAttribute)
        return keys.isEmpty ? nil : keys
    }

    // MARK: Styles

    /// Refuses a style that gives an attribute no kind drawn here has (a typo, most likely).
    private mutating func check(_ style: StyleDefinition) throws(DrawError) {
        let kinds = drawableKinds.map { vocabulary(of: ShapeKind(rawValue: $0)) }
        let everything = Set(kinds.flatMap(\.attributes))
        for attribute in style.attributes where LanguageKey(rawValue: attribute.key) == nil && !everything.contains(attribute.key) {
            let guess = Suggestions.closest(to: attribute.key, among: everything.sorted(), limit: 1).first
            throw DrawError("style \(style.name) has \(attribute.key):, which is an attribute of nothing drawn here",
                            reason: ScriptError.Reason.unknownAttribute.rawValue,
                            hint: guess.map { "did you mean \($0)?" } ?? "\(program) kinds lists each kind's attributes",
                            line: style.line, statement: style.text)
        }
    }

    // MARK: Messages

    /// The board the run draws on, as a message names it: `"Plans"'s board`.
    var boardName: String { FileNames.named(target.board, in: editor, naming: naming) }

    /// How a message names a statement's shape: `"API"`, or `the card on line 3`.
    func subject(of item: ShapeItem) -> String {
        said(item) ?? item.idWritten ?? item.standsFor.map { "the \(item.kind) to \($0)" } ?? "the \(item.kind) on line \(item.statement.line)"
    }

    /// A board shape's middle.
    func middle(of record: AnyShapeRecord) -> CGPoint {
        (target.shapes.geometry(of: record.id)?.bounds ?? record.box).map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
    }

    /// A board shape, named for a message: `"DB"`, or `card at 400,300` (its middle); unquoted, as
    /// a row names it.
    func named(_ record: AnyShapeRecord, quote: Bool = true) -> String {
        guard let title = Drawing.title(of: record, names: names, naming: naming, registry: registry) else {
            return Drawing.location(of: record, in: target.shapes)
        }
        return quote ? sharedName(of: record) ?? quoted(title) : title
    }

    // MARK: The board

    /// The board's connections as the run starts, read the first time they're asked for (a delete
    /// asks as the run starts; an edge that may go through a stand-in asks as it's resolved), with
    /// those that join no two shapes. Nothing without DrawEdges.
    mutating func boardConnections() -> [BoardConnection] {
        if !connectionsRead {
            connectionsRead = true
            if let edging, let edgeKind {
                connections = Self.connections(in: target.document, kind: edgeKind, edging: edging, registry: registry)
                looseConnections = Self.looseConnections(in: target.shapes, kind: edgeKind, edging: edging)
            }
        }
        return connections
    }

    /// Whether this run moves a board shape: restates it with placements, or moves a container that
    /// holds it. Asked once every shape statement is known, as an edge is resolved.
    mutating func movesWithRun(_ id: ShapeID) -> Bool {
        if movingShapes == nil { movingShapes = Set(items.compactMap { $0.moves ? $0.existing?.id : nil }) }
        guard let moving = movingShapes, !moving.isEmpty else { return false }
        if moving.contains(id) { return true }
        let kinds = registry.containingKinds
        return !kinds.isEmpty && target.document.containers(of: id, containingKinds: kinds).contains(where: moving.contains)
    }

    static func connections(in document: CanvasDocument, kind: ShapeKind, edging: DrawEdging, registry: Registry) -> [BoardConnection] {
        document.shapes.compactMap { record in
            guard record.kind == kind, !record.isOpaque, let ends = edging.ends(record, registry) else { return nil }
            return BoardConnection(record: record, from: ends.from, to: ends.to)
        }
    }

    /// The connections that don't join two shapes (an end left free, re-aimed off every shape),
    /// by each shape they're bound to (`ShapeReferencing`), in document order.
    static func looseConnections(in context: ShapeContext, kind: ShapeKind, edging: DrawEdging) -> [ShapeID: [AnyShapeRecord]] {
        var found: [ShapeID: [AnyShapeRecord]] = [:]
        for record in context.document.shapes where record.kind == kind && !record.isOpaque && edging.ends(record, context.registry) == nil {
            for id in record.boundShapes(in: context) { found[id, default: []].append(record) }
        }
        return found
    }
}

/// The board's shapes by what they're called, as the run starts.
@MainActor
struct BoardNames {
    /// Each name's shapes, in document order.
    private(set) var ids: [String: [ShapeID]] = [:]
    /// Each name once, in document order: what "did you mean" picks from.
    private(set) var ordered: [String] = []
    private var byID: [ShapeID: String] = [:]
    /// Each name, with its place in `ordered`, by its length as titles are compared: a near miss is
    /// at most 2 letters longer or shorter, so a new title is held only to names about its length.
    private var byLength: [Int: [(order: Int, name: String)]] = [:]

    init() {}

    init(_ document: CanvasDocument, naming: DrawNaming, registry: Registry) {
        self.init(document.shapes.lazy.filter { !$0.isOpaque }.compactMap { record in naming.name(record, registry).map { ($0, record.id) } })
    }

    /// From a board's named shapes, in document order (`FileNames.entries(on:)`, read once for the
    /// whole file).
    init(_ entries: some Sequence<(name: String, id: ShapeID)>) {
        for (name, id) in entries {
            if ids[name] == nil {
                byLength[Self.comparedLength(name), default: []].append((ordered.count, name))
                ordered.append(name)
            }
            ids[name, default: []].append(id)
            byID[id] = name
        }
    }

    func name(of record: AnyShapeRecord) -> String? { byID[record.id] }

    /// The first name, in document order, that `title` is a slip of (`Suggestions.isNearMiss`),
    /// among those `included`.
    func nearMiss(of title: String, where included: (String) -> Bool) -> String? {
        let length = Self.comparedLength(title)
        let nearby = (length - Self.slip...length + Self.slip).flatMap { byLength[$0] ?? [] }.sorted { $0.order < $1.order }
        return nearby.first { included($0.name) && Suggestions.isNearMiss(title, $0.name) }?.name
    }

    /// The most letters a near miss is off by.
    private static let slip = 2

    /// A title's length as `Suggestions` compares titles: runs of whitespace one space, the ends
    /// trimmed (lowercasing it, and writing × as x, keep its length).
    static func comparedLength(_ title: String) -> Int {
        let words = title.split(whereSeparator: \.isWhitespace)
        return words.reduce(0) { $0 + $1.count } + max(words.count - 1, 0)
    }
}

extension Script {
    /// Whether any statement names a shape by title (so the board's names are needed).
    var mentionsTitles: Bool {
        statements.contains { statement in
            switch statement.body {
            case .shape(let shape):
                shape.name != nil || shape.clauses.contains { $0.targets.contains(where: \.isName) }
            case .edge, .delete, .group, .ungroup: true
            }
        }
    }
}

extension Attribute.Value {
    /// Its text, whatever it is: a word, a quoted string's, a JSON value's as written.
    var text: String {
        switch self {
        case .word(let text), .quoted(let text), .json(let text): text
        }
    }
}

/// A title in straight double quotes, escaped as a script writes it.
public func quoted(_ title: String) -> String {
    var escaped = ""
    for character in title {
        switch character {
        case "\"": escaped += "\\\""
        case "\\": escaped += "\\\\"
        case "\n": escaped += "\\n"
        case "\t": escaped += "\\t"
        default: escaped.append(character)
        }
    }
    return "\"\(escaped)\""
}

/// A word with its article, as a message names one of a kind: `a sticky-note`, `an arrow`.
public func indefinite(_ word: some CustomStringConvertible) -> String {
    let text = word.description
    return (text.first.map { "aeiou".contains($0.lowercased()) } ?? false ? "an " : "a ") + text
}

/// `a`, `a and b`, `a, b and c` (or `or`).
func listed(_ items: [String], or: Bool = false) -> String {
    guard let last = items.last else { return "" }
    return items.count == 1 ? last : "\(items.dropLast().joined(separator: ", ")) \(or ? "or" : "and") \(last)"
}

/// A point as a message writes it: `400,300`, to the unit (a coordinate too far out for a whole
/// number, as it is).
func point(_ point: CGPoint) -> String {
    func unit(_ value: CGFloat) -> String { Int(exactly: value.rounded()).map(String.init) ?? "\(value)" }
    return "\(unit(point.x)),\(unit(point.y))"
}
