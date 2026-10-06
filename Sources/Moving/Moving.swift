import Canvas
import CoreGraphics
import DrawScript
import SlashCommands

/// Moving, as a plugin: two slash commands that move the shape whose text they're typed in to another
/// shape, anywhere in the file the app can show. `/move-to @Groceries` puts it in a frame, or onto a
/// subboard's board; `/move-near @Checkout` puts it beside a shape, on the first of its four sides
/// that's free, or, with none free, on the side that frees up nearest. Where it lands is worked out as
/// `canvas draw` places a shape (DrawScript's solver, against the shapes of the board it lands on, filed
/// in an `ObstacleGrid`), and it's moved and put down with the core's own tools, as draw's commit is:
/// `translate`, `move(_:to:)` onto another board, then the in-or-out rule (`settle`). A feature no kind
/// opts into and nothing imports, as Jump To and Reordering are: the commands go on every kind a drag
/// moves, the kinds whose shapes have a box.
public struct MovingPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "moving" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.slashCommandsForEveryShape(where: { hasBox($0.definition) }) {
            // Asked only of the shapes that hold shapes or own boards (frames, subboards), so its rule
            // may look further than move-near's.
            SlashCommand("move-to", argument: "@frame or subboard", kinds: { $0.containingKinds.union($0.boardOwningKinds) },
                         shapes: { target, owner, editor in Destination(of: owner, into: target, in: editor) != nil },
                         step: MovingStyle.stepName) { id, arguments, editor in
                guard let target = arguments.shapes.first else { return }
                Move(id, in: editor)?.into(target)
            }
            // Asked of every shape the `@` picker ranks, as the person types.
            SlashCommand("move-near", shapes: { target, owner, editor in admitsNear(target, for: owner, in: editor) },
                         step: MovingStyle.stepName) { id, arguments, editor in
                guard let target = arguments.shapes.first else { return }
                Move(id, in: editor)?.near(target)
            }
        }
    }
}

/// Moving's constants.
@MainActor
enum MovingStyle {
    /// The undo step either command makes: a drag's name, so Edit › Undo Move takes it back.
    static let stepName = "Move"
    /// The sides `/move-near` tries, in order: of the sides that land as near the shape, the first wins.
    static let sides: [Direction] = [.right, .below, .left, .above]
    /// The corners `/move-to` tries in a frame, in reading order: the first with room wins.
    static let corners: [Part] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

/// Whether a kind's shapes have a box (`BoxShapeProps`): the kinds a drag moves, which the commands go on.
@MainActor
private func hasBox<Definition: ShapeDefinition>(_: Definition) -> Bool { Definition.Props.self is any BoxShapeProps.Type }

// MARK: What each command takes

/// Where `/move-to` puts a shape.
enum Destination: Equatable {
    /// In a shape that holds shapes on its board (a frame), on that board.
    case container(ShapeID, on: BoardID)
    /// Onto the board a shape owns (a subboard's).
    case board(BoardID)

    /// The board the shape lands on.
    var board: BoardID {
        switch self {
        case .container(_, on: let board), .board(let board): board
        }
    }
}

extension Destination {
    /// Where `/move-to` puts `shape` (on the board shown) for `target`; nil for a target it doesn't take.
    /// It takes a shape that holds shapes (a frame) or owns a board (a subboard), on any board of the file
    /// the app can show (`editor.shape(inFile:)`), but:
    /// - the shape itself, and what goes with it: what it holds, at any depth, and what's on a board it,
    ///   or a shape it holds, owns, or on one under that (`goesWith`);
    /// - one that's read-only on its board (locked, or in a locked frame): it takes nothing;
    /// - where the shape is already: the frame it's directly in, the subboard whose board it's on;
    /// - a frame too small to hold it (narrower or shorter than it);
    /// - a frame on another board that takes no shapes: one whose owner is read-only on its own board
    ///   (the rule `move(_:to:)` refuses by).
    /// What it's asked of is the kinds the command names (frames and subboards), so it may cost what a
    /// target's depth in the file does.
    @MainActor
    init?(of shape: ShapeID, into target: ShapeID, in editor: CanvasEditor) {
        let registry = editor.registry, file = editor.file
        guard target != shape, let moving = editor.document[shape], let box = moving.box,
              let found = editor.shape(inFile: target), !found.isOpaque, let board = file.board(containing: target),
              !registry.isReadOnly(found, in: editor.contents(of: board)) else { return nil }
        // A subboard, as `canvas draw`'s `in` takes one: onto its board.
        if registry.ownsShowableBoard(found) {
            let owned = BoardID(owner: target)
            guard owned != editor.board, !(takesAlong(moving, in: registry) && goesWith(target, onto: owned, shape, in: editor)) else { return nil }
            self = .board(owned)
            return
        }
        guard registry.isContainer(found), let frame = found.box, box.width <= frame.width, box.height <= frame.height,
              editor.document.container(of: moving, containingKinds: registry.containingKinds) != target,
              !(takesAlong(moving, in: registry) && goesWith(target, onto: board, shape, in: editor)) else { return nil }
        if board != editor.board, let owner = board.owner {
            guard let holder = file.record(owner), let ownerBoard = file.board(containing: owner),
                  !registry.isReadOnly(holder, in: editor.contents(of: ownerBoard)) else { return nil }
        }
        self = .container(target, on: board)
    }
}

/// Whether `/move-near` takes `target` for `shape`: any shape but the shape itself, and, for a shape that
/// holds shapes or owns a board (rare: a note does neither), none that goes with it (`goesWith`). Asked
/// of every shape the `@` picker ranks as the person types, so it costs next to nothing. A read-only
/// target is fine (it doesn't change), and whether the target's board takes shapes is the move's to say
/// (it refuses, and the board's owner shakes where it's shown).
@MainActor
func admitsNear(_ target: ShapeID, for shape: ShapeID, in editor: CanvasEditor) -> Bool {
    guard target != shape else { return false }
    guard let moving = editor.document[shape], takesAlong(moving, in: editor.registry),
          let board = editor.file.board(containing: target) else { return true }
    return !goesWith(target, onto: board, shape, in: editor)
}

/// Whether moving a shape takes other shapes with it: it holds shapes (a frame), or owns a board (a
/// subboard).
@MainActor
func takesAlong(_ shape: AnyShapeRecord, in registry: Registry) -> Bool {
    registry.isContainer(shape) || registry.ownsShowableBoard(shape)
}

/// Whether moving `shape` to `target`, onto `board`, would take either with it, so it's nowhere `shape`
/// can go: `target` is the shape, or in it at any depth, or `board` is on the way down through a board
/// the shape, or a shape in it, owns (one of them owns a board on the file's path to `board`,
/// `CanvasFile.path(to:)`). What `move(_:to:)`'s preconditions trap on, asked the way they ask it: the
/// owners above the board it lands on, against what moves. O(the board's depth and what the shape holds).
@MainActor
func goesWith(_ target: ShapeID, onto board: BoardID, _ shape: ShapeID, in editor: CanvasEditor) -> Bool {
    let kinds = editor.registry.containingKinds
    var moving: Set<ShapeID> = [shape]
    if !kinds.isEmpty { moving.formUnion(editor.document.descendants(of: shape, containingKinds: kinds)) }
    guard !moving.contains(target) else { return true }
    // No way down from the root (an owner not in the file): no board the editor can show, which the
    // move refuses on its own.
    guard let path = editor.file.path(to: board) else { return false }
    return path.contains { $0.owner.map(moving.contains) ?? false }
}
