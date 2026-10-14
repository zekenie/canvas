import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import TestKit

// What a shape still needs, said of a shape a run did not write. The fixture check is the crowd check's cousin: a tile
// that no link ends at still needs one (an issue of the third level, not a warning and not an error), and a run's
// writes reach the tiles its links end at, or ended at. Of a shape the run wrote it is no warning (its row's
// `problems` say it, where a plugin gives them); of one it did not write, it is a warning with its own `severity`.

/// The editor, to read a deleted link's end from.
@MainActor private final class Holder {
    weak var editor: CanvasEditor?
}

/// Checks shapes: a tile no link ends at needs one.
@MainActor private func needyPlugin(_ holder: Holder) -> Contributor {
    Contributor(id: "checks") { registrar in
        registrar.drawChecks(touched: { changes, shapes in
            var found: Set<ShapeID> = []
            for id in changes.shapeIDs {
                let records: [AnyShapeRecord?] = [shapes.shape(id), holder.editor?.document[id]]
                for record in records {
                    if let to = record?.typed(as: Link.self)?.props.to { found.insert(to) }
                }
            }
            return found
        }, rest: #"canvas query ":incomplete""#) { record, shapes -> [DrawIssue] in
            guard let tile = record.typed(as: Tile.self) else { return [] }
            var issues: [DrawIssue] = []
            if tile.props.finish == .glossy { issues.append(DrawIssue("A glossy tile glares.", isError: true, field: "finish")) }
            if !shapes.document.shapes.contains(where: { $0.typed(as: Link.self)?.props.to == tile.id }) {
                issues.append(DrawIssue("it needs a link", level: .incomplete, field: "links"))
            }
            return issues
        }
    }
}

/// Hub, with a link from A; B alone.
@MainActor private func needyEditor() throws -> CanvasEditor {
    let holder = Holder()
    let editor = try makeEditor([namesPlugin(), edgesPlugin(), needyPlugin(holder)])
    holder.editor = editor
    let hub = tile("Hub", CGRect(x: 400, y: 200, width: 120, height: 80), in: editor)
    let a = tile("A", CGRect(x: 100, y: 200, width: 120, height: 80), in: editor)
    tile("B", CGRect(x: 400, y: 500, width: 120, height: 80), in: editor)
    link(a, hub, in: editor)
    return editor
}

private func needs(_ title: String, line: Int?) -> JSON {
    var warning: [String: JSON] = ["message": .string("\"\(title)\": it needs a link"), "severity": "incomplete", "attribute": "links"]
    if let line { warning["line"] = .number(Double(line)) }
    return .object(warning)
}

@MainActor let drawIncompleteTests = Suite("draw: what a run leaves a shape it did not write needing", [
    test("a delete that leaves a tile needing a link says so once, with the line and the level") {
        let editor = try needyEditor()
        let result = try drawn(#"delete edge "A" -> "Hub""#, on: editor)
        expectEqual(result["warnings"], [needs("Hub", line: 1)])
    },
    test("a shape the run wrote needing something is no warning, and neither is one it restated") {
        let editor = try needyEditor()
        // D is new and has no link; the run wrote it.
        expectEqual(try drawn(#"tile "D" below "A""#, on: editor)["warnings"], [], "D is the run's own")
        // Hub is written (finish changed) while its link goes: the glare is its statement's, the need is no warning.
        let result = try drawn(#"""
        tile "Hub" finish: glossy
        delete edge "A" -> "Hub"
        """#, on: editor)
        expectEqual(result["warnings"], [["line": 1, "message": #""Hub": A glossy tile glares."#, "severity": "error", "attribute": "finish"]])
    },
    test("a run that mends it, or leaves it as it was, says nothing") {
        let editor = try needyEditor()
        // B needed a link, and has one now: mended, and not said. Hub is looked at too, and has what it had.
        expectEqual(try drawn(#"edge "A" -> "B""#, on: editor)["warnings"], [], "B is mended")
        expectEqual(try drawn(#"edge "A" -> "B""#, on: editor)["warnings"], [], "as it was")
        // And a link that goes brings it back, which is another run's.
        expectEqual(try drawn(#"delete edge "A" -> "B""#, on: editor)["warnings"], [needs("B", line: 1)])
    },
    test("a shape restated as it is was not written: what it needs is said once, on the line of the statement that left it so") {
        let editor = try needyEditor()
        let result = try drawn(#"""
        tile "Hub"
        delete edge "A" -> "Hub"
        """#, on: editor)
        expectEqual(result["warnings"], [needs("Hub", line: 2)])
    },
    test("a dry run says the same, and changes nothing") {
        let editor = try needyEditor()
        let before = editor.document, revision = editor.revision
        let dry = try drawn(#"delete edge "A" -> "Hub""#, on: editor, ["--dry-run"])
        expectEqual(dry["warnings"], [needs("Hub", line: 1)])
        expectEqual(editor.document, before)
        expectEqual(editor.revision, revision)
        expectEqual(try drawn(#"delete edge "A" -> "Hub""#, on: editor)["warnings"], dry["warnings"])
    },
    test("the shapes counted past twenty are counted with the others, and the command lists the level too") {
        let holder = Holder()
        let editor = try makeEditor([namesPlugin(), edgesPlugin(), needyPlugin(holder)])
        holder.editor = editor
        let source = tile("S", CGRect(x: 0, y: 0, width: 120, height: 80), in: editor)
        var script: [String] = []
        for index in 1...22 {
            let name = "T" + String(format: "%02d", index)
            let made = tile(name, CGRect(x: 200 + Double(index) * 140, y: 0, width: 120, height: 80), in: editor)
            link(source, made, in: editor)
            script.append(#"delete edge "S" -> "\#(name)""#)
        }
        let warnings = try drawn(script.joined(separator: "\n"), on: editor)["warnings"]?.arrayValue ?? []
        expectEqual(warnings.count, 21)
        expectEqual(warnings.dropLast().allSatisfy { $0["severity"] == "incomplete" }, true)
        expectEqual(warnings.last, ["message": #"and 2 more shapes now have issues: ask canvas query ":incomplete""#, "severity": "warning"])
    },
])
