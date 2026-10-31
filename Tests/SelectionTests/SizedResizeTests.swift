@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// A kind laid out past its box resizes once it takes a frame its own way (`CustomSizing`): a sheet,
// laid out no shorter than what it holds needs, as a note is no shorter than its words. Its handles
// sit on the frame it's laid out in, it's handed each frame the pointer gives it with the ways the
// handle gives, and a side that the sheet keeps out stops there with the side opposite put.

/// A box laid out no shorter than `needs`, which keeps a height it's given (`least`); a fixed one isn't
/// resized.
private struct Sheet: BoxShapeProps {
    static let kind: ShapeKind = "sized-sheet"
    static let properties = Properties<Sheet> {
        Property("frame", \.frame).required()
        Property("needs", \.needs)
        Property("least", \.least)
        Property("fixed", \.fixed)
    }
    var frame: CGRect
    var needs: CGFloat
    var least: CGFloat?
    var fixed: Bool
    init(_ frame: CGRect, needs: CGFloat = 0, fixed: Bool = false) {
        self.frame = frame
        self.needs = needs
        self.fixed = fixed
    }
    init() { self.init(.zero) }
}

/// The ways each frame was given, in order.
@MainActor private final class SheetLog {
    var given: [SizeAxes] = []
}

private struct SheetDefinition {
    let log: SheetLog
}

extension SheetDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Sheet>, in context: RenderContext) {}
}

extension SheetDefinition: LaidOutBox {
    func laidOutSize(of shape: ShapeRecord<Sheet>, in context: ShapeContext) -> CGSize {
        CGSize(width: shape.frame.width, height: max(shape.frame.height, shape.props.needs))
    }
}

extension SheetDefinition: CustomSizing {
    func size(_ sheet: inout ShapeRecord<Sheet>, to frame: CGRect, giving axes: SizeAxes, in context: ShapeContext) {
        log.given.append(axes)
        sheet.props.frame = frame
        if axes.contains(.height) { sheet.props.least = frame.height }
    }

    func isResizable(_ shape: ShapeRecord<Sheet>, in context: ShapeContext) -> Bool { !shape.props.fixed }
}

private struct SheetsPlugin: CanvasPlugin {
    let log: SheetLog
    var id: PluginID { "sized-sheets" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(SheetDefinition(log: log)) { sheet in sheet.resizable(minimumSize: CGSize(width: 20, height: 20)) }
    }
}

/// A sheet stored 200 by 50 at (100, 100) that needs 120, so laid out 200 by 120, selected alone.
@MainActor private func sheetHarness(fixed: Bool = false) throws -> (EditorHarness, ShapeID, SheetLog) {
    let log = SheetLog()
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), SheetsPlugin(log: log)])
    let sheet = h.add(Sheet(CGRect(x: 100, y: 100, width: 200, height: 50), needs: 120, fixed: fixed))
    h.editor.replaceDocument(with: h.editor.document)          // nothing to undo
    h.editor.selection = sheet
    return (h, sheet, log)
}

extension EditorHarness {
    /// A shape's laid-out frame.
    @MainActor fileprivate func laidOut(_ id: ShapeID) -> CGRect? { editor.shapeContext.frame(of: id) }

    /// Presses `handle` of the frame `id` is laid out in, drags it `by` view points in two steps, and lets go.
    @MainActor fileprivate func resizeLaidOut(_ id: ShapeID, _ handle: ResizeHandle, by delta: CGPoint) {
        guard let frame = laidOut(id) else { return }
        let start = view(point(of: handle, on: frame))
        move(to: start)
        press(at: start)
        drag(to: start + delta / 2)
        drag(to: start + delta)
        release()
    }
}

@MainActor let sizedResizeTests = Suite("Resizing a kind that takes a frame its own way", [
    test("its handles are on the frame it's laid out in, not on the box it stores") {
        let (h, sheet, _) = try sheetHarness()
        let laid = CGRect(x: 100, y: 100, width: 200, height: 120)
        expectEqual(h.laidOut(sheet), laid)
        expectEqual(h.editor.handle(atViewPoint: point(of: .bottomRight, on: laid)), AnyHashable(ResizeHandle.bottomRight))
        expectEqual(h.editor.handle(atViewPoint: point(of: .bottom, on: laid)), AnyHashable(ResizeHandle.bottom))
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 300, y: 150)), AnyHashable(ResizeHandle.right),
                    "the stored box's corner is along the right side of the laid-out frame")
    },
    test("a corner's drag gives it the frame both ways; it takes it as it says") {
        let (h, sheet, log) = try sheetHarness()
        h.resizeLaidOut(sheet, .bottomRight, by: CGPoint(x: 40, y: 60))
        expectEqual(h.laidOut(sheet), CGRect(x: 100, y: 100, width: 240, height: 180))
        let stored = try require(h.editor.document[sheet]?.typed(as: Sheet.self))
        expectEqual(stored.props.least, 180, "the height it was given")
        expectEqual(Set(log.given), [SizeAxes.both])
        expectEqual(h.editor.undoHistory.undoName, "Resize")
    },
    test("a side's drag gives one way, the other as it is; ⇧ on a side gives both") {
        let (h, sheet, log) = try sheetHarness()
        h.resizeLaidOut(sheet, .right, by: CGPoint(x: 30, y: 0))
        expectEqual(Set(log.given), [SizeAxes.width])
        expectEqual(try require(h.editor.document[sheet]?.typed(as: Sheet.self)).props.least, nil, "no height given")
        log.given = []
        h.resizeLaidOut(sheet, .bottom, by: CGPoint(x: 0, y: 30))
        expectEqual(Set(log.given), [SizeAxes.height])
        log.given = []
        h.hold(.shift)
        h.resizeLaidOut(sheet, .right, by: CGPoint(x: 30, y: 0))
        expectEqual(Set(log.given), [SizeAxes.both])
    },
    test("dragged past what it needs, a side stops there: the bottom's top stays, the top's bottom stays") {
        let (h, sheet, _) = try sheetHarness()
        h.resizeLaidOut(sheet, .bottom, by: CGPoint(x: 0, y: -90))
        expectEqual(h.laidOut(sheet), CGRect(x: 100, y: 100, width: 200, height: 120), "no shorter than it needs, from its top")
        expectEqual(try require(h.editor.document[sheet]?.typed(as: Sheet.self)).props.least, 30, "though it keeps what it was given")
        h.resizeLaidOut(sheet, .top, by: CGPoint(x: 0, y: 70))
        expectEqual(h.laidOut(sheet), CGRect(x: 100, y: 100, width: 200, height: 120), "the bottom stays put, so nothing moves")
        h.resizeLaidOut(sheet, .top, by: CGPoint(x: 0, y: -40))
        expectEqual(h.laidOut(sheet), CGRect(x: 100, y: 60, width: 200, height: 160), "taller than it needs, it follows the pointer")
        h.hold(.option)
        h.resizeLaidOut(sheet, .bottom, by: CGPoint(x: 0, y: -60))
        expectEqual(h.laidOut(sheet), CGRect(x: 100, y: 80, width: 200, height: 120), "from its center, it stays about its middle")
    },
    test("Escape puts the shape back as it was, and leaves no step") {
        let (h, sheet, _) = try sheetHarness()
        let before = h.editor.document[sheet]
        let corner = point(of: .bottomRight, on: try require(h.laidOut(sheet)))
        h.press(at: corner)
        h.drag(to: corner + CGPoint(x: 30, y: 40))
        expectEqual(h.laidOut(sheet), CGRect(x: 100, y: 100, width: 230, height: 160))
        h.escape()
        expectEqual(h.editor.document[sheet], before)
        h.release()
        expect(!h.editor.canUndo, "the step came to nothing")
    },
    test("⌥ and an arrow resize the frame it's laid out in") {
        let (h, sheet, log) = try sheetHarness()
        let right = "\u{F703}", down = "\u{F701}"
        h.hold(.option)
        expect(h.key(down))
        expectEqual(h.laidOut(sheet), CGRect(x: 100, y: 100, width: 200, height: 121), "a unit past the frame it's laid out in")
        expect(h.key(right))
        expectEqual(h.laidOut(sheet), CGRect(x: 100, y: 100, width: 201, height: 121))
        expectEqual(log.given, [.height, .width])
    },
    test("a shape its kind says doesn't resize has no handles, no parts, and ⌥ and an arrow pass") {
        let (h, sheet, _) = try sheetHarness(fixed: true)
        let laid = try require(h.laidOut(sheet))
        for handle in ResizeHandle.allCases {
            expectEqual(h.editor.handle(atViewPoint: point(of: handle, on: laid)), nil, "\(handle)")
        }
        expectEqual(h.editor.shapeParts(of: sheet).count, 0)
        h.hold(.option)
        _ = h.key("\u{F701}")
        expectEqual(h.laidOut(sheet), laid, "not resized")
    },
])
