import Canvas
import CanvasRPC

// The params of the commands over the draw engine (Draw): what `canvas` reads their arguments by
// (`x-stdin` is the command line's), checked and decoded before a command runs.

struct DrawParams: SchemaDefined {
    static let properties = Properties<DrawParams>(title: "draw") {
        Property("script", \.script).required().keywords(["x-stdin": true, "x-value-name": "script"])
            .description("What to draw: one statement a line (a shape, an edge, a delete, a group or a style), in quotes for the shell.")
        Property("dryRun", \.dryRun).description("Work everything out and say what would happen, changing nothing.")
        Property("reveal", \.reveal).description("Then ease the view to what was drawn.")
    }
    var script = ""
    var dryRun = false
    var reveal = false
}

struct MeasureParams: SchemaDefined {
    static let properties = Properties<MeasureParams>(title: "measure") {
        Property("script", \.script).required().keywords(["x-stdin": true, "x-value-name": "script"])
            .description("A draw script, as `draw` takes it: what to measure. Where shapes go is ignored.")
    }
    var script = ""
}

struct ListKinds: SchemaDefined {
    static let properties = Properties<ListKinds>(title: "kinds") {
        Property("kind", \.kind).description("Just this kind.")
        Property("schema", \.schema).description("With each kind's JSON Schema.")
    }
    var kind: String?
    var schema = false
}
