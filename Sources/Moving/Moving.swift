import Canvas
import CoreGraphics
import SlashCommands
import TableOfContents

/// Moving, as a plugin: two slash commands that move the shapes they're typed for (the shape whose text
/// they're typed in, or the shapes selected) to another shape, anywhere in the file the app can show.
/// `/move-to @Groceries` puts them in a frame, or onto a subboard's board; `/move-near @Checkout` puts
/// them beside a shape, on the first of its four sides that's free, or, with none free, on the side that
/// frees up nearest. Several move as one block, kept where they are to each other. Where they land is
/// worked out as `canvas draw` places a shape (DrawScript's solver, against the shapes of the board they
/// land on, filed in an `ObstacleGrid`), and they're moved and put down with the core's own tools, as
/// draw's commit is: `translate`, `move(_:to:)` onto another board, then the in-or-out rule (`settle`).
/// And the table of contents' drops that take shapes into a frame, onto a subboard's board, or out of
/// frames (`ContentsMoves`), placed the same way, several at once as one block, and Move To ▸ in the
/// selection's menu, by the same rule: `/move-to` takes a place while the drop of the shapes there is
/// admitted (`Drop`), and runs that drop, so the command, the menu and the table of contents refuse and
/// land alike. A feature no kind opts into and nothing imports, as Jump To and Reordering are: the
/// commands go on every kind a drag moves, the kinds whose shapes have a box
/// (`forShapes(adopting: .box)`).
public struct MovingPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "moving" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.forShapes(adopting: .box) { boxes in
            boxes.slashCommands {
                // Asked only of the shapes that hold shapes or own boards (frames, subboards), so its rule
                // may look further than move-near's. Handed every shape it acts on, to move as one block.
                SlashCommand.together("move-to", argument: "@frame or subboard", kinds: { $0.containingKinds.union($0.boardOwningKinds) },
                                      shapes: { target, owners, editor in admitsInto(target, for: owners, in: editor) },
                                      step: MovingStyle.stepName) { owners, arguments, editor in
                    guard let target = arguments.shapes.first else { return }
                    Move(owners, in: editor)?.into(target)
                }
                // Asked of every shape the `@` picker ranks, as the person types.
                SlashCommand.together("move-near", shapes: { target, owners, editor in admitsNear(target, for: owners, in: editor) },
                                      step: MovingStyle.stepName) { owners, arguments, editor in
                    guard let target = arguments.shapes.first else { return }
                    Move(owners, in: editor)?.near(target)
                }
            }
        }
        // Move To ▸ in the selection's menu, on the same kinds.
        registrar.forShapes(adopting: .box) { registerMoveToMenu(into: &$0) }
        registrar.contentsMoves(admits: { shapes, place, editor in Drop(shapes, to: place, in: editor) != nil },
                                move: { shapes, place, editor in Drop(shapes, to: place, in: editor)?.commit() })
    }
}

/// Moving's constants.
@MainActor
enum MovingStyle {
    /// The undo step either command makes: a drag's name, so Edit › Undo Move takes it back.
    static let stepName = "Move"
    /// The submenu of the selection's menu.
    static let moveTo = "Move To"
    /// The most places it lists.
    static let menuLimit = 20
    /// What it calls the file's root board when the file has no name.
    static let rootBoard = "Board"
}

// MARK: What each command takes

/// The place a shape stands for as a destination, as Move To ▸ names a place: the board it owns, for a
/// shape that owns one (a subboard, as `canvas draw`'s `in` takes one), else inside it, on `board`, the
/// board it's on, for a shape that holds shapes (a frame); in front of what's there. Nil for any other
/// shape.
@MainActor
func contentsPlace(of shape: AnyShapeRecord, on board: BoardID, in registry: Registry) -> ContentsPlace? {
    if registry.ownsShowableBoard(shape) { return ContentsPlace(board: BoardID(owner: shape.id), container: nil, position: .front) }
    guard registry.isContainer(shape) else { return nil }
    return ContentsPlace(board: board, container: shape.id, position: .front)
}

/// Where `/move-to` puts shapes for `target`: the place `contentsPlace(of:on:in:)` makes of it, wherever
/// the target is in the file the app can show (`editor.shape(inFile:)`): a frame on another board is a
/// place on that board. Nil for a shape that is neither a frame nor a subboard, one kept aside, and one
/// that is on no board of the file.
@MainActor
func movePlace(of target: ShapeID, in editor: CanvasEditor) -> ContentsPlace? {
    guard let found = editor.shape(inFile: target), !found.isOpaque, let board = editor.file.board(containing: target) else { return nil }
    return contentsPlace(of: found, on: board, in: editor.registry)
}

/// Whether `/move-to` takes `target` for `shapes`: the shape it names is a place (`movePlace(of:in:)`) and
/// the shapes can be dropped there (`Drop`), the rule Move To ▸ lists its places by and the table of
/// contents' drops are admitted by. So the three refuse alike: shapes that aren't all on the board shown
/// (or have no box), a place that goes with them (the shape itself, what it holds at any depth, what's on a
/// board it, or a shape it holds, owns), shapes or a place that's read-only (locked, in a locked frame, or
/// on a board that takes no shapes: a locked subboard's, at any depth), shapes already in the place (the
/// frame they're directly in, the subboard whose board they are on), a board the app can't show, and a frame
/// too small for the box around the shapes coming in from elsewhere. It lays nothing out. What it's asked of
/// is the kinds the command names (frames and subboards).
@MainActor
func admitsInto(_ target: ShapeID, for shapes: [ShapeID], in editor: CanvasEditor) -> Bool {
    guard let place = movePlace(of: target, in: editor) else { return false }
    return Drop(shapes, to: place, in: editor) != nil
}

/// Whether `/move-near` takes `target` for `shapes`: any shape but the shapes themselves, and, for a shape
/// among them that holds shapes or owns a board (rare: a note does neither), none that goes with it
/// (`goesWith`), at any depth. Asked of every shape the `@` picker ranks as the person types, so it costs
/// next to nothing. A read-only target is fine (it doesn't change), and whether the target's board takes
/// shapes is the move's to say (it refuses, and the board's owner shakes where it's shown).
@MainActor
func admitsNear(_ target: ShapeID, for shapes: [ShapeID], in editor: CanvasEditor) -> Bool {
    guard !shapes.contains(target) else { return false }
    let registry = editor.registry, kinds = registry.containingKinds
    var moving: Set<ShapeID> = []
    for shape in shapes {
        guard let record = editor.document[shape], takesAlong(record, in: registry) else { continue }
        moving.insert(shape)
        if !kinds.isEmpty { moving.formUnion(editor.document.descendants(of: shape, containingKinds: kinds)) }
    }
    guard !moving.isEmpty, let board = editor.file.board(containing: target) else { return true }
    return !goesWith([target], onto: board, moving: moving, in: editor)
}

/// Whether moving a shape takes other shapes with it: it holds shapes (a frame), or owns a board (a
/// subboard).
@MainActor
func takesAlong(_ shape: AnyShapeRecord, in registry: Registry) -> Bool {
    registry.isContainer(shape) || registry.ownsShowableBoard(shape)
}

/// Whether moving `moving` (shapes, and what they hold at any depth) to `targets` (a frame to go in, a
/// shape to go beside), onto `board`, would take any of them with it: one of `targets` is among what
/// moves, or one of what moves owns a board on the file's path to `board` (`CanvasFile.path(to:)`). What
/// `move(_:to:)`'s preconditions trap on, asked the way they ask it: the owners above the board it lands
/// on, against what moves. O(the board's depth).
@MainActor
func goesWith(_ targets: [ShapeID], onto board: BoardID, moving: Set<ShapeID>, in editor: CanvasEditor) -> Bool {
    guard !targets.contains(where: moving.contains) else { return true }
    // No way down from the root (an owner not in the file): no board the editor can show, which the
    // move refuses on its own.
    guard let path = editor.file.path(to: board) else { return false }
    return path.contains { $0.owner.map(moving.contains) ?? false }
}
