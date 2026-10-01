import Canvas
import CoreGraphics
import Geometry

/// The Frame tool (F): a drag draws a frame from the press to the pointer (`DrawingFrameSession`), a
/// click places one of `Frame.defaultSize` centered on it. Either way the frame is put down as a place
/// tool puts its shape down (`editor.place`): one undo step, "Add Frame", settled in or out of the
/// frames it lands in (so one drawn in a frame is in it) and taking in what's mostly inside it, gliding
/// what that nudges, selected, with the default tool back. Into a locked frame, nothing is put down,
/// and the locked frame shakes.
@MainActor
final class FrameTool {
    let placement: Placement
    init(placing placement: Placement) { self.placement = placement }
}

extension FrameTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        editor.session = DrawingFrameSession(placing: placement, from: pointer)
    }
}

/// A frame being drawn, from the press to the pointer, shown over what it's drawn on (its surface at
/// `FrameStyle.previewFillOpacity`, so what it will take in shows through) until the release puts it
/// down (`editor.place(_:in:)`), never smaller than `Frame.minimumSize`, grown from the press toward
/// the pointer. ⇧ draws a square, ⌥ draws it about its center, as a resize keeps its proportions and
/// its center, each taking effect as it's pressed or let go. It's drawn once the pointer has gone
/// `FrameStyle.smallestDrawn` from the press along either axis; a release before that is a click (its
/// jitter draws nothing), which places a frame of `Frame.defaultSize` centered on the press. The
/// canvas scrolls at its edges while it runs. Escape puts nothing down.
@MainActor
final class DrawingFrameSession {
    private let placement: Placement
    /// Where it was pressed, in world units.
    private let origin: CGPoint
    /// The last pointer, to draw again from when held keys change.
    private var last: Pointer
    /// Whether the pointer has gone far enough from the press to draw: until then it's a click.
    private var isDrawing = false

    init(placing placement: Placement, from pointer: Pointer) {
        self.placement = placement
        origin = pointer.world
        last = pointer
    }

    /// The frame as drawn so far, in world units: nil while it's a click.
    private var drawn: CGRect? {
        guard isDrawing else { return nil }
        return Self.rect(from: origin, to: last.world, square: last.modifiers.contains(.shift), fromCenter: last.modifiers.contains(.option),
                         minimum: Frame.minimumSize)
    }

    /// The rect a drag from `origin` to `corner` draws (world units): from the press to the pointer,
    /// or with `fromCenter` about the press; with `square`, as wide as it's tall, by its longer side;
    /// each side at least `minimum`'s, grown away from the press toward the pointer.
    static func rect(from origin: CGPoint, to corner: CGPoint, square: Bool, fromCenter: Bool, minimum: CGSize) -> CGRect {
        let reach: CGFloat = fromCenter ? 2 : 1
        var width = max(abs(corner.x - origin.x) * reach, minimum.width)
        var height = max(abs(corner.y - origin.y) * reach, minimum.height)
        if square {
            width = max(width, height)
            height = width
        }
        func start(_ press: CGFloat, _ pointer: CGFloat, _ length: CGFloat) -> CGFloat {
            fromCenter ? press - length / 2 : pointer < press ? press - length : press
        }
        return CGRect(x: start(origin.x, corner.x, width), y: start(origin.y, corner.y, height), width: width, height: height)
    }
}

extension DrawingFrameSession: Session {
    var scrollsAtEdges: Bool { true }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        last = pointer
        if !isDrawing {
            let press = editor.camera.toView(origin)
            isDrawing = max(abs(pointer.view.x - press.x), abs(pointer.view.y - press.y)) >= FrameStyle.smallestDrawn
        }
        if isDrawing { editor.setNeedsDisplay() }
    }

    /// ⇧ or ⌥ came or went: drawn again where the pointer is, without its moving.
    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) {
        var pointer = last
        pointer.world = editor.camera.toWorld(pointer.view)
        pointer.modifiers = modifiers
        drag(pointer, in: editor)
    }

    /// The release puts the frame down: as drawn, or a click's, centered on the press.
    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        drag(pointer, in: editor)
        if let rect = drawn {
            editor.place(placement, in: rect)
        } else {
            editor.place(placement, at: origin)
        }
    }

    /// Escape: nothing is put down, and the Frame tool stays.
    func cancel(in editor: CanvasEditor) -> Bool { true }

    func draw(in context: OverlayContext) {
        guard let rect = drawn else { return }
        FrameStyle.draw(rect, zoom: context.zoom, fillOpacity: FrameStyle.previewFillOpacity, in: context.cg)
    }
}

extension FrameStyle {
    /// How far from the press the pointer goes, along either axis, in view points, before a frame is
    /// drawn: short of it, a click's jitter, which places a frame of `Frame.defaultSize`.
    static let smallestDrawn: CGFloat = 12
}
