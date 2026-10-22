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
/// then the boards that enclose it, innermost first; at most `MovingStyle.menuLimit`.
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
        let place: ContentsPlace
        if registry.ownsShowableBoard(record) {
            place = ContentsPlace(board: BoardID(owner: record.id), container: nil, position: .front)
        } else if registry.isContainer(record) {
            place = ContentsPlace(board: editor.board, container: record.id, position: .front)
        } else {
            continue
        }
        guard let frame = context.frame(of: record) else { continue }
        near.append((hypot(frame.center.x - middle.x, frame.center.y - middle.y), record.id, place))
    }
    near.sort { $0.distance < $1.distance }
    var found: [MovePlace] = []
    let title = { (record: AnyShapeRecord) in editor.tableOfContents?.name(of: record) ?? registry.label(of: record.kind).name }
    for candidate in near {
        guard found.count < MovingStyle.menuLimit else { return found }
        if Drop(shapes, to: candidate.place, in: editor) != nil { found.append(MovePlace(title: editor.document[candidate.id].map(title) ?? "", place: candidate.place)) }
    }
    for board in editor.boardPath.dropLast().reversed() {
        guard found.count < MovingStyle.menuLimit else { break }
        let place = ContentsPlace(board: board, container: nil, position: .front)
        guard Drop(shapes, to: place, in: editor) != nil else { continue }
        let title = editor.owner(of: board).map(title) ?? (editor.rootName.isEmpty ? MovingStyle.rootBoard : editor.rootName)
        found.append(MovePlace(title: title, place: place))
    }
    return found
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
