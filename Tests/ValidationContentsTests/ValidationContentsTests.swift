import Canvas
import CanvasTesting
import CoreGraphics
import SwiftUI
import TableOfContents
import TestKit
import Validation
import ValidationContents

/// A box with no height has an error, one with no width a warning. A tag's rule looks up the shape
/// it points at: pointing at nothing is an error, and at a flat box a warning.
let sizeRules = Contributor(id: "rules") { r in
    r.validate(Box.self) { box, _ in
        (box.frame.width == 0 ? [.warning("No width.")] : []) + (box.frame.height == 0 ? [.error("No height.")] : [])
    }
    r.validate(Tag.self) { tag, context in
        guard let target = tag.props.target.flatMap({ context.shape($0) }) else { return [.error("Points at nothing.")] }
        return target.box?.height == 0 ? [.warning("Points at something flat.")] : []
    }
}

@MainActor func editor(_ plugins: [any CanvasPlugin]) throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: [FixturesPlugin()] + plugins), scheduler: ManualScheduler())
}

@MainActor func shipped() throws -> CanvasEditor {
    try editor([ValidationPlugin(), TableOfContentsPlugin(), ValidationContentsPlugin(), sizeRules])
}

extension CanvasEditor {
    /// The marks on the shape's row, the whole board listed.
    func marks(_ id: ShapeID) throws -> [ContentsMark] {
        try require(require(tableOfContents).entries.first { $0.id == id }, "no row for \(id)").marks
    }
}

@MainActor let validationContentsTests = Suite("Validation in the table of contents", [
    test("a shape with an error is marked red, one with only warnings orange, a valid one not at all") {
        let editor = try shipped()
        let both = editor.add(Box(.zero))
        let warned = editor.add(Box(CGRect(x: 0, y: 0, width: 0, height: 40)))
        let valid = editor.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        expectEqual(try editor.marks(both).map(\.color), [Color(nsColor: Severity.error.color)])
        expectEqual(try editor.marks(warned).map(\.color), [Color(nsColor: Severity.warning.color)])
        expectEqual(try editor.marks(valid), [])
    },
    test("the mark's tooltip lists the shape's issues, worst first") {
        let editor = try shipped()
        let box = editor.add(Box(.zero))
        expectEqual(try editor.marks(box).map(\.help), ["No height.\nNo width."])
    },
    test("marks follow the document, even for a shape that didn't change: a rule's look at another shape") {
        let editor = try shipped()
        let box = editor.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        let tag = editor.add(Tag(target: box))
        _ = try require(editor.tableOfContents).entries
        expectEqual(try editor.marks(tag), [])
        let tagBefore = editor.document[tag]
        editor.transact { $0.update(box, as: Box.self) { $0.frame.size.height = 0 } }
        expectEqual(editor.document[tag], tagBefore, "the tag didn't change")
        expectEqual(try editor.marks(box).map(\.help), ["No height."])
        expectEqual(try editor.marks(tag).map(\.help), ["Points at something flat."], "its mark did")
        editor.transact { $0.update(box, as: Box.self) { $0.frame.size.height = 40 } }
        expectEqual(try editor.marks(tag), [])
        editor.transact { $0.delete([box]) }
        expectEqual(try editor.marks(tag).map(\.help), ["Points at nothing."])
    },
    test("without validation installed, no row is marked") {
        let editor = try editor([TableOfContentsPlugin(), ValidationContentsPlugin()])
        expectEqual(try editor.marks(editor.add(Box(.zero))), [])
    },
    test("without the table of contents installed, the bridge is refused") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ContentsMarks", owner: .tableOfContents, contributor: "validation-contents")) {
            _ = try Registry(plugins: [FixturesPlugin(), ValidationPlugin(), ValidationContentsPlugin()])
        }
    },
    test("the bridge is one line in the report, and contributes to Validation nothing") {
        let registry = try Registry(plugins: [ValidationPlugin(), TableOfContentsPlugin(), ValidationContentsPlugin()])
        expectEqual(registry.report, """
        core                 tool hand · command undo · command redo · command zoomIn · command zoomOut · command zoomToActualSize · command zoomToFit
        validation           service ValidationEngine · overlay ValidationOverlay · ValidationRules
        table-of-contents    service ContentsState
        validation-contents  ContentsMarks
        """)
    },
])
