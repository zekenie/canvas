import Adornments
import Canvas
import CoreGraphics
import DrawScript
import Topology

// `canvas measure`: how big a draw script's shapes would be, and what they reach, without drawing it.
// A tool that lays shapes out before it draws them (the canvas-digest skill's) needs what the app alone
// knows: the size draw would make each shape (a note as tall as its text at its width, a note that is a type as
// tall as its text), how far its title's pill reaches above it, how wide a reference to a shape is
// for its title, and the constants of the placement it will draw with. It reads the script as `draw`
// does, ignores where shapes go (placements, `in`), and answers for each shape statement, and each edge
// that says it goes through a reference (`via:`). It changes nothing: the shapes are made on a board of
// its own that is thrown away, by the same `Drawing` a draw uses, so the sizes are the ones a draw makes,
// and no board's undo step opens. The edges that go through no reference are kept, to lay the shapes out
// with: an end gives the notes of its type a row, a draw's `at` says so, and so must a measure. Given a
// board, the script is laid out over that board's own editor (read, never written).

/// What `measure` answers.
public struct MeasureResult: Encodable {
    /// A name measuring couldn't find: its line, and what it did.
    struct Warning: Encodable {
        let line: Int
        let message: String
    }

    /// A shape statement: what draw would make of it.
    struct Shape: Encodable {
        let line: Int
        let title: String?
        let kind: String
        /// Width and height, world units.
        let size: [CGFloat]
        /// How far its title's pill and chips reach above its top edge, world units at 100% zoom (0 for none).
        let above: CGFloat
    }

    /// An edge that says `via:`: the stand-in draw would put beside its start, standing for its end.
    struct Reference: Encodable {
        let line: Int
        let target: String
        let size: [CGFloat]

        enum CodingKeys: String, CodingKey {
            case line, size
            case target = "for"
        }
    }

    /// What placement is done with, read from the source it is done by.
    struct Constants: Encodable {
        /// Every named gap (`gap: tight`), world units.
        let gaps: [String: CGFloat]
        /// How far apart a placement holds two boxes when nothing says.
        let defaultGap: CGFloat
        /// Between the members of a list drawn beside a shape.
        let listStep: CGFloat
        /// Between the references beside a shape (`LayoutProblem.impliedListStep`).
        let referenceStep: CGFloat
        /// Kept between two boxes pushed apart side by side, and one above the other.
        let horizontalClearance: CGFloat
        let verticalClearance: CGFloat
        /// How far `in "F"` puts what it holds from F's top-left corner.
        let frameInset: CGFloat
        /// The smallest a kind is drawn (`Placement.minimumSize`), for the kinds that have one.
        let smallest: [String: [CGFloat]]
    }

    let shapes: [Shape]
    let references: [Reference]
    let constants: Constants
    /// Names it couldn't find, left out when there are none.
    let warnings: [Warning]?
}

/// How big a script's shapes would be, as `draw` would make them, over `registry`'s kinds. `program`
/// is the name its hints give the command line that runs it. `editor` is the board it is given, if
/// any: the open file's names and types are read from it (`Drawing.namesBeyond`), never written.
@MainActor
public func measure(script text: String, program: String, in registry: Registry, namesBeyond editor: CanvasEditor?) throws(DrawError) -> MeasureResult {
    let script: Script
    do throws(ScriptErrors) {
        script = try Script(parsing: text)
    } catch {
        throw collected(error.errors.map { DrawError($0) })
    }

    // Where a shape goes isn't measured: its placements and the shape holding it are left out, and so is
    // everything that isn't a shape or an edge through a reference.
    var statements: [Statement] = []
    var through: [(statement: Statement, edge: EdgeStatement)] = []
    for statement in script.statements {
        switch statement.body {
        case .shape(var shape):
            shape.clauses = []
            shape.container = nil
            // Every shape is new in a measure, as it is for a title the file has: one that names a shape by its id is measured as
            // a new shape of its kind with no title, and one a path names as a new shape titled by its last part (the container the
            // path leads through is left out as `in` is; two paths are two shapes, whatever their last parts are).
            if shape.name?.id != nil { shape.name = nil }
            statements.append(Statement(line: statement.line, text: statement.text, body: .shape(shape)))
        case .edge(var edge):
            // Through a reference, an edge is only the reference's size (a pill is sized, never drawn here: it may stand for a
            // note that isn't public), wherever it says the reference goes. Any other is laid out with the shapes (an end gives its
            // type's notes a row), as draw does.
            edge.clauses = []
            edge.container = nil
            if edge.via != nil {
                through.append((statement, edge))
            } else if registry.drawEdging != nil {
                statements.append(Statement(line: statement.line, text: statement.text, body: .edge(edge)))
            }
        case .delete, .group, .ungroup:
            break
        }
    }

    // A board of its own, empty, so every title is new, as on a new file; the open file's types and names are read from the editor
    // it was given, if any (`namesBeyond`).
    let scratch = CanvasEditor(registry: registry)
    guard let reading = scratch.reading(of: .root) else {
        throw DrawError("a board to measure on couldn't be made", reason: ScriptError.Reason.internal.rawValue)
    }
    let drawing = try Drawing(Script(statements: statements, styles: script.styles), editor: scratch, on: reading, namesBeyond: editor,
                              measuring: true, program: program)

    let shapes = drawing.items.map { item in
        var record = item.record
        record.box = CGRect(origin: .zero, size: item.room)
        return MeasureResult.Shape(line: item.statement.line, title: drawing.naming?.name(item.record, registry), kind: item.kind.rawValue,
                                   size: [item.room.width, item.room.height], above: scratch.adornmentExtent(of: record))
    }

    let standIns = registry.standIns
    var references: [MeasureResult.Reference] = []
    for (statement, edge) in through {
        guard let word = edge.via else { continue }
        let kind = try Drawing.standInKind(named: word, among: standIns, statement, written: "\(Keyword.edge.rawValue) \(edge.written)")
        let label: String
        switch edge.to {
        case .title(let written): label = drawing.fold(written) ?? written
        case .id(let text): label = drawing.measuredLabel(ofID: text) ?? edge.to.written
        // A pill is called what the shape is: the last part of its path.
        case .path(let path): label = drawing.fold(path.last) ?? path.last
        }
        guard let size = standIns.make(kind, standingFor: ShapeID(), label: label)?.box?.size else {
            throw DrawError(statement, .internal, "\(indefinite(kind)) couldn't be made to stand for \(quoted(label))")
        }
        references.append(MeasureResult.Reference(line: statement.line, target: label, size: [size.width, size.height]))
    }

    var smallest: [String: [CGFloat]] = [:]
    for kind in registry.kinds {
        guard let least = registry.placement(for: kind)?.minimumSize, least != .zero else { continue }
        smallest[kind.rawValue] = [least.width, least.height]
    }
    let gaps = Dictionary(uniqueKeysWithValues: GapName.allCases.map { ($0.rawValue, $0.value) })
    return MeasureResult(shapes: shapes, references: references,
                         constants: MeasureResult.Constants(
                             gaps: gaps, defaultGap: LayoutProblem.defaultGap, listStep: LayoutProblem.listStep,
                             referenceStep: LayoutProblem.impliedListStep, horizontalClearance: LayoutProblem.horizontalClearance,
                             verticalClearance: LayoutProblem.verticalClearance, frameInset: LayoutProblem.insideGap, smallest: smallest),
                         warnings: drawing.measureWarnings.isEmpty ? nil : drawing.measureWarnings.map { MeasureResult.Warning(line: $0.line, message: $0.message) })
}
