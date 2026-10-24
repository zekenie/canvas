import Boards
import Canvas
import ContextMenus
import CoreGraphics
import TableOfContents

/// Where Move To ▸ sits in the selection's menu: after what changes what a shape is (Transform's, Frames'), right
/// before what it is made from (Lock, Is a ▸) and Delete.
enum MoveToMenuGroup {}
extension MoveToMenuGroup: MenuGroup {
    static var order: Order<Self> { .before(StateMenuGroup.self) }
}

/// Move To ▸, in the menu of every selection whose shapes have boxes (which is also the menu bar's Shape
/// menu): the places the selection can go, as the table of contents' drop would take it (`Drop`, so the
/// same refusals and the same landing, in one step, Move). A plain `NSMenu`, which the keys already
/// walk and type to select in. The frames and subboards of the board shown, nearest the selection first,
/// then the boards that enclose it, innermost first; at most `MovingStyle.menuLimit`. A place is called
/// as its row in the table of contents is, and by its path ("Alpha › Checkout": the containers it is
/// inside, outermost first, as every path names them, Boards' `ShapePaths`) where another place in the
/// menu is called alike.
@MainActor
func registerMoveToMenu(into scope: inout ScopedRegistrar) {
    scope.contextMenuForCanvas {
        MenuItems(in: MoveToMenuGroup.self, id: "move-to") { subject in
            let places = movePlaces(for: subject.shapes, in: subject.editor)
            if !places.isEmpty {
                Submenu(MovingStyle.moveTo, in: MoveToMenuGroup.self, id: "move-to") {
                    for (index, place) in places.enumerated() {
                        MenuItem(place.title, in: MoveToMenuGroup.self, id: "move-to-\(index)", stepName: MovingStyle.stepName) { ids, editor in
                            Drop(ids, to: place.place, in: editor)?.commit()
                        }
                    }
                }
            }
        }
    }
}

/// A place the menu offers.
struct MovePlace {
    let title: String
    let place: ContentsPlace
}

/// The places `shapes` can go, as `Drop` admits them, nearest first, capped.
@MainActor
func movePlaces(for shapes: [ShapeID], in editor: CanvasEditor) -> [MovePlace] {
    guard !shapes.isEmpty else { return [] }
    let registry = editor.registry
    let context = editor.shapeContext
    let boxes = shapes.compactMap { editor.document[$0].flatMap { context.frame(of: $0) } }
    guard boxes.count == shapes.count else { return [] }
    let middle = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }.center
    var near: [(distance: CGFloat, id: ShapeID, place: ContentsPlace)] = []
    for record in editor.document.shapes where !record.isOpaque {
        // A subboard's board, else inside a frame: the place `/move-to` makes of a shape it's told.
        guard let place = contentsPlace(of: record, on: editor.board, in: registry), let frame = context.frame(of: record) else { continue }
        near.append((hypot(frame.center.x - middle.x, frame.center.y - middle.y), record.id, place))
    }
    near.sort { $0.distance < $1.distance }
    var found: [MovePlace] = []
    var owners: [ShapeID?] = []
    // A place with no title is called what a path calls it ("Untitled Subboard", "Frame"), as its row shows it.
    let title = { (record: AnyShapeRecord) in editor.tableOfContents?.name(of: record) ?? registry.containerName(of: record).text }
    for candidate in near {
        guard found.count < MovingStyle.menuLimit else { break }
        if Drop(shapes, to: candidate.place, in: editor) != nil {
            found.append(MovePlace(title: editor.document[candidate.id].map(title) ?? "", place: candidate.place))
            owners.append(candidate.id)
        }
    }
    for board in editor.boardPath.dropLast().reversed() where found.count < MovingStyle.menuLimit {
        let place = ContentsPlace(board: board, container: nil, position: .front)
        guard Drop(shapes, to: place, in: editor) != nil else { continue }
        let title = editor.owner(of: board).map(title) ?? (editor.rootName.isEmpty ? MovingStyle.rootBoard : editor.rootName)
        found.append(MovePlace(title: title, place: place))
        owners.append(board.owner)
    }
    // Two places called alike are told apart by where they are: the containers each is inside, from the root, never
    // trimmed to the board shown (a frame in a subboard and the board above it would be alike again).
    var counts: [String: Int] = [:]
    for place in found { counts[place.title.lowercased(), default: 0] += 1 }
    var paths = ShapePaths(editor: editor)
    for index in found.indices where counts[found[index].title.lowercased(), default: 0] > 1 {
        guard let owner = owners[index] else { continue }
        let names = paths.containers(of: owner).map { paths.node($0).name.text } + [found[index].title]
        found[index] = MovePlace(title: names.joined(separator: ShapePath.separator), place: found[index].place)
    }
    return found
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
