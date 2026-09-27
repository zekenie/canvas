import CanvasRPC
import Foundation
import TestKit

/// A command whose params are one of each kind of value, as an app would describe them (its point
/// and size as the core's schemas write them).
let sample = CommandSpec(
    name: "create", summary: "Put a shape on a board.", discussion: "It goes in the middle of the view.", scope: .board,
    params: [
        "type": "object",
        "properties": [
            "kind": ["type": "string", "description": "The kind."],
            "at": ["$ref": "#/$defs/core.point", "description": "Where its middle goes."],
            "size": ["$ref": "#/$defs/core.size"],
            "set": ["type": "array", "items": ["type": "string"], "x-value-name": "name=value", "description": "A property."],
            "props": ["type": "object"],
            "count": ["type": "integer"],
            "scale": ["type": "number", "default": 1],
            "startArrowhead": ["type": "boolean"],
            "status": ["type": "string", "oneOf": [["const": "todo", "title": "To do"], ["const": "done", "title": "Done"]]],
        ],
        "required": ["kind"],
        "additionalProperties": false,
        "$defs": [
            "core.point": ["description": "[x, y]", "type": "array", "prefixItems": [["type": "number"], ["type": "number"]], "items": false, "minItems": 2],
            "core.size": ["description": "[width, height]", "type": "array", "prefixItems": [["type": "number"], ["type": "number"]], "items": false, "minItems": 2],
        ],
    ],
    positionals: ["kind"],
    examples: [CommandExample("canvas create note --at 10,20", "A note at (10, 20).")])

@MainActor func parse(_ arguments: [String], input: String = "") throws(ArgumentError) -> [String: JSON] {
    try sample.params(from: arguments, standardInput: { input })
}

@MainActor func parseError(_ arguments: [String]) -> ArgumentError? {
    do throws(ArgumentError) {
        _ = try parse(arguments)
        return nil
    } catch {
        return error
    }
}

@MainActor let argumentTests = Suite("Arguments", [
    test("each value is written as its schema says: text, numbers, a point, a flag, a list, JSON, a choice") {
        let params = try parse(["note", "--at", "10,-20.5", "--size=200, 100", "--set", "text=Hi", "--set", "title=T", "--props", #"{"a": 1}"#,
                                "--count", "3", "--start-arrowhead", "--status", "done", "--board", "2"])
        expectEqual(JSON.object(params), [
            "kind": "note", "at": [10, -20.5], "size": [200, 100], "set": ["text=Hi", "title=T"], "props": ["a": 1], "count": 3,
            "startArrowhead": true, "status": "done", "board": "2",
        ])
    },
    test("a flag is on, off with --no-, or says which; a camelCase option may be typed either way") {
        expectEqual(try parse(["n", "--no-start-arrowhead"])["startArrowhead"], false)
        expectEqual(try parse(["n", "--start-arrowhead=false"])["startArrowhead"], false)
        expectEqual(try parse(["n", "--startArrowhead"])["startArrowhead"], true)
        expectEqual(try parse(["n", "--scale", "2.5"])["scale"], 2.5)
    },
    test("a point may be JSON; a positional may come after the options, or be given by name") {
        expectEqual(try parse(["--at", "[1, 2]", "note"]), ["kind": "note", "at": [1, 2]])
        expectEqual(try parse(["--kind", "note"]), ["kind": "note"])
    },
    test("-- ends the options, so a value may start with them") {
        expectEqual(try parse(["--", "--odd"]), ["kind": "--odd"])
    },
    test("JSON given as - is read from standard input") {
        expectEqual(try parse(["n", "--props", "-"], input: #"{"b": [true]}"#)["props"], ["b": [true]])
    },
    test("arguments that don't spell the params say what's wrong, and what would help") {
        expectEqual(parseError([])?.message, "create needs <kind>")
        expectEqual(parseError([])?.hint, "Usage: \(sample.usage())")
        let unknown = parseError(["n", "--st", "x"])
        expectEqual(unknown?.message, "create has no option --st")
        expectEqual(unknown?.hint, "Did you mean --set?")
        expectEqual(parseError(["n", "--at", "1"])?.message, "--at is 2 numbers, as x,y, not 1")
        expectEqual(parseError(["n", "--at", "1,x"])?.message, "--at is 2 numbers, as x,y, not 1,x")
        expectEqual(parseError(["n", "--count", "1.5"])?.message, "--count is a whole number, not 1.5")
        expectEqual(parseError(["n", "--scale", "big"])?.message, "--scale is a number, not big")
        let choice = parseError(["n", "--status", "don"])
        expectEqual(choice?.message, "--status is one of todo, done, not don")
        expectEqual(choice?.hint, "Did you mean done?")
        expectEqual(parseError(["n", "--at", "1,2", "--at", "3,4"])?.message, "--at is given twice")
        expectEqual(parseError(["n", "m"])?.message, "create doesn't take m")
        expectEqual(parseError(["n", "--props", "{nope"])?.message, "--props takes JSON, which '{nope' isn't")
        expectEqual(parseError(["n", "--at"])?.message, "--at needs a value: <x,y>")
        expectEqual(parseError(["n", "--start-arrowhead=maybe"])?.message, "--start-arrowhead is on or off: true or false, not maybe")
    },
    test("an app command takes no --board") {
        var app = sample
        app.scope = .app
        do throws(ArgumentError) {
            _ = try app.params(from: ["n", "--board", "1"], standardInput: { "" })
            expect(false, "it took --board")
        } catch {
            expectEqual(error.message, "create has no option --board")
        }
    },
    test("usage and help come from the schema: value names, choices, defaults, what repeats, examples") {
        expectEqual(sample.usage(), "canvas create <kind> [--at <x,y>] [--count <number>] [--props <json>] [--scale <number>] "
            + "[--set <name=value>]... [--size <width,height>] [--start-arrowhead] [--status <todo|done>] [--board <board>]")
        let help = sample.help()
        expect(help.hasPrefix("Put a shape on a board.\n\nUsage: canvas create <kind>"), help)
        expect(help.contains("It goes in the middle of the view."), help)
        expect(help.contains("Arguments:\n  <kind>"), help)
        expect(help.contains("--at <x,y>"), help)
        expect(help.contains("Where its middle goes."), help)
        expect(help.contains("--scale <number>"), help)
        expect(help.contains("Default: 1."), help)
        expect(help.contains("A property. Repeatable."), help)
        expect(help.contains("Examples:\n  canvas create note --at 10,20\n      A note at (10, 20)."), help)
        expect(help.contains("--board <board>"), help)
    },
])
