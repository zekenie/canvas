import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import TestKit
import TextEditing
import Titles

// The title typed in its pill (`TitleField`) and titles as bars zoomed out (`title(bars: true)`), on a sign: a box kind of the
// test's own whose name is typed in its pill as it lands (an editing placement) and said as a bar zoomed out. A sign at
// (100, 100), 200 × 120, at 100% from the origin, so view points are world units: its pill's row is 27 to 9 points above it.

struct Sign: BoxShapeProps {
    static let kind: ShapeKind = "sign"
    static let properties = Properties<Sign> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

@MainActor
struct SignDefinition {}

extension SignDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Sign>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .white)
    }
}

extension SignDefinition: Editable {
    func editingFrame(of shape: ShapeRecord<Sign>, in context: ShapeContext) -> CGRect? {
        TitleField.editingFrame(around: shape.frame, zoom: context.zoom)
    }

    func makeEditingView(for shape: ShapeRecord<Sign>, context: EditContext<Sign>) -> EditingView {
        TitleField.editingView(for: shape, context: context, systemImage: "signpost.right", tint: nil, name: "Sign name")
    }

    var editingStepName: String? { "Rename Sign" }
}

/// Signs: the Sign tool, placing one whose name is typed at once; titled with the symbol in the pill, bars zoomed out; with
/// `tinted`, a look tinting their pills green.
struct SignsPlugin: CanvasPlugin {
    var tinted = false
    var id: PluginID { "signs" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(SignDefinition()) { sign in
            sign.label("Sign", systemImage: "signpost.right")
            sign.tool(label: "Sign", systemImage: "signpost.right", placing: sign.editingPlacement(size: CGSize(width: 200, height: 120)) { Sign() })
            sign.title(symbolInPill: true, bars: true)
            if tinted { sign.titlePillLook { _, _ in TitlePillLook(tint: AdornmentTint(.systemGreen, style: .solid)) } }
        }
    }
}

@MainActor private func signs(tinted: Bool = false) throws -> (CanvasEditor, ShapeID) {
    let editor = try titleEditor([SignsPlugin(tinted: tinted)])
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    var sign = ShapeRecord(Sign(CGRect(x: 100, y: 100, width: 200, height: 120)))
    sign[TitleProperty.self] = "Exit"
    editor.transact { $0.insert(sign) }
    return (editor, sign.id)
}

@MainActor private func field(_ editor: CanvasEditor) throws -> TitleField {
    try require(editor.makeEditingView()?.view as? TitleFieldHost).titleField
}

@MainActor let titleFieldTests = Suite("A title typed in its pill", [
    test("its editing frame is the shape and the pill's row above it, from its left end; the field is on that row, as tall as the pill, at 100% and zoomed") {
        let (editor, sign) = try signs()
        for zoom in [1.0, 2.0, 0.5] as [CGFloat] {
            editor.camera = Camera(origin: .zero, zoom: zoom)
            let pill = try require(editor.titlePillRect(of: sign))
            editor.beginEditing(sign)
            let frame = try require(editor.editingFrame)
            expectEqual(frame.minX, 100)
            expectEqual(frame.minY, pill.minY, "the pill's top at \(zoom)")
            expectEqual(frame.maxY, 220, "and the shape's bottom")
            let host = try require(editor.makeEditingView()?.view as? TitleFieldHost)
            host.frame = CGRect(x: 0, y: 0, width: frame.width * zoom, height: frame.height * zoom)
            host.bounds = CGRect(origin: .zero, size: frame.size)
            host.layoutSubtreeIfNeeded()
            expectEqual(host.titleField.frame.minY, 0)
            expectEqual(host.titleField.frame.height, pill.height, "as tall as the pill at \(zoom)")
            expectEqual(host.titleField.field.font?.pointSize ?? 0, AdornmentLabel.rowFont.pointSize * pill.height / AdornmentLayout.rowHeight,
                        "the pill's text, in world units at \(zoom)")
            expect(host.hitTest(CGPoint(x: 10, y: frame.height * zoom - 4)) == nil, "the shape under the row isn't the field's")
            expect(host.hitTest(CGPoint(x: 4, y: pill.height * zoom / 2)) != nil, "the chip is")
            editor.endEditing()
        }
    },
    test("each change is the title, in the session's step; Return ends it; a blank title is none; the chip grows with what's typed") {
        let (editor, sign) = try signs()
        editor.beginEditing(sign)
        let typed = try field(editor)
        expectEqual(typed.field.string, "Exit", "its title, the caret after it")
        expectEqual(typed.field.accessibilityLabel(), "Sign name")
        let before = typed.chipWidth
        typed.field.insertText(" left", replacementRange: NSRange(location: 4, length: 0))
        expectEqual(editor.name(sign), "Exit left")
        expect(typed.chipWidth > before, "the chip as wide as what's typed")
        typed.field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        expectEqual(editor.editingShapeID, nil)
        expectEqual(editor.undoHistory.undoName, "Rename Sign")
        editor.beginEditing(sign)
        let blank = try field(editor)
        blank.field.insertText("   ", replacementRange: NSRange(location: 0, length: blank.field.string.utf16.count))
        blank.field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(editor.name(sign), nil, "a blank title is none, and Escape keeps it")
    },
    test("put down by its tool, its name is typed at once, and joins the step that placed it") {
        let editor = try titleEditor([SignsPlugin()])
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        expect(editor.insert(ToolID(placing: Sign.kind), beside: []))
        let made = try require(editor.document.shapes.first { $0.kind == Sign.kind })
        expectEqual(editor.editingShapeID, made.id)
        let typed = try field(editor)
        typed.field.insertText("Fire exit", replacementRange: NSRange(location: 0, length: 0))
        typed.field.doCommand(by: #selector(NSResponder.insertTab(_:)))
        expectEqual(editor.editingShapeID, nil, "Tab ends it too")
        expectEqual(editor.name(made.id), "Fire exit")
        expectEqual(editor.undoHistory.undoName, "Add Sign")
    },
    test("zoomed out, its title is a bar where its pill is, as long as its title reads, with no cover; a look's tint colors it") {
        let (editor, sign) = try signs()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        expect(editor.drawsSkeleton(of: sign))
        expectEqual(editor.titleCover(of: sign), nil, "no cover on the shape")
        let drawn = renderBitmap(editor, size: CGSize(width: 200, height: 120))
        // The sign is 30 to 90 across and 30 to 66 down; its pill's row 3 to 21 down, the bar 40% of it (7.2) just above the sign's
        // top, 1.5 clear of it (21.3 to 28.5), so it reads as the sign's and never as the footer of a shape above (UX walk 3 evolve-8).
        expect(pixel(drawn, at: CGPoint(x: 36, y: 25))[0] < 120, "the bar, the pill's gray: \(pixel(drawn, at: CGPoint(x: 36, y: 25)))")
        expect(pixel(drawn, at: CGPoint(x: 36, y: 12))[0] > 200, "not up where the pill's row is")
        expect(pixel(drawn, at: CGPoint(x: 36, y: 4))[0] > 200, "the bar is thinner than the pill")
        expect(pixel(drawn, at: CGPoint(x: 88, y: 25))[0] > 200, "as long as Exit, not the sign")
        let (tinted, green) = try signs(tinted: true)
        tinted.camera = Camera(origin: .zero, zoom: 0.3)
        let colored = pixel(renderBitmap(tinted, size: CGSize(width: 200, height: 120)), at: CGPoint(x: 36, y: 25))
        expect(colored[1] > colored[0] + 40, "a look's tint: \(colored)")
        tinted.transact { $0.update(green) { $0[TitleProperty.self] = nil } }
        expect(pixel(renderBitmap(tinted, size: CGSize(width: 200, height: 120)), at: CGPoint(x: 36, y: 25))[1] > 200, "an untitled one has none")
    },
])
