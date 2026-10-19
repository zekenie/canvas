import Canvas
import CanvasTesting
import Foundation
import TestKit
import Validation

@MainActor let keptAsideValidationTests = Suite("Validating kept-aside shapes", [
    test("rules for every shape pass over shapes the board keeps aside") {
        let registry = try Registry(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.forEveryShape { scope in
                scope.validate { _, _ in [.warning("seen")] }
            }
        }])
        let box = ShapeID(), kept = ShapeID()
        let json = """
        { "format" : 1, "schema" : { "box" : 0 }, "shapes" : [
          { "id" : "\(box)", "index" : "a0", "kind" : "box", "props" : { "frame" : [[0, 0], [40, 40]] } },
          { "id" : "\(kept)", "index" : "a1", "kind" : "gadget", "props" : { } } ] }
        """
        let document = try BoardCodec(registry: registry).decode(Data(json.utf8)).document
        let editor = CanvasEditor(registry: registry, document: document)
        expectEqual(Array(try require(editor.validation).results.keys), [box])
        expectEqual(registry.validationIssues(of: try require(document[kept]), in: editor.shapeContext), [], "nor are they asked of one")
        expectEqual(registry.validationIssues(of: try require(document[box]), in: editor.shapeContext).map(\.message), ["seen"])
    },
])
