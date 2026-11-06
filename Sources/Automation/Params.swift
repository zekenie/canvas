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
        Property("drawing", \.drawing).keywords(["x-value-name": "name"])
            .description("Join a drawing: every shape the script names is kept in the drawing's record, with what it now is, so a later query says what changed since.")
    }
    var script = ""
    var dryRun = false
    var reveal = false
    var drawing: String?
}

struct ApplyParams: SchemaDefined {
    static let properties = Properties<ApplyParams>(title: "apply") {
        Property("document", \.document).required().keywords(["x-stdin": true, "x-value-name": "document", "x-timeout": 300])
            .description("The document to draw: JSON, its nodes and edges by key, with places.")
        Property("dryRun", \.dryRun).description("Work everything out and say what would happen, changing nothing.")
        Property("on", \.on).keywords(["x-value-name": "name"])
            .description("The shape whose board the document's top goes on (a subboard), by its title, a path or #<id>; else where the drawing is, else the top board.")
    }
    var document = ""
    var dryRun = false
    var on: String?
}

struct RehearseParams: SchemaDefined {
    static let properties = Properties<RehearseParams>(title: "rehearse") {
        Property("scripts", \.scripts).required().keywords(["x-stdin": true, "x-value-name": "scripts", "x-timeout": 120])
            .description("The scripts to draw in turn: a JSON list of strings, each a script as `draw` takes it.")
    }
    var scripts = ""
}

struct MeasureParams: SchemaDefined {
    static let properties = Properties<MeasureParams>(title: "measure") {
        Property("script", \.script).required().keywords(["x-stdin": true, "x-value-name": "script"])
            .description("A draw script, as `draw` takes it, or a document (JSON, its nodes and edges by key): what to measure. Where shapes go is ignored.")
        Property("on", \.on).keywords(["x-value-name": "name"])
            .description("A document's: the board it will be drawn on, as apply's --on names it (a subboard's title, a path or #id): a pill says where its shape is from there. Left out, where the drawing was drawn, else the root.")
    }
    var script = ""
    var on: String?
}

struct ListKinds: SchemaDefined {
    static let properties = Properties<ListKinds>(title: "kinds") {
        Property("kind", \.kind).description("Just this kind.")
        Property("schema", \.schema).description("With each kind's JSON Schema.")
    }
    var kind: String?
    var schema = false
}
