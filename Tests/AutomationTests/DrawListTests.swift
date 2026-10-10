import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import TestKit

// A quoted value for a list of text is a list of that one item; several are JSON. And what a script's
// settings imply (`drawImplies`): a concern's rule that one change comes with another, in the same
// step. Over a roster, which holds lists, and a stamp, which implies a seal.

struct Roster: BoxShapeProps {
    static let kind: ShapeKind = "roster"
    static let properties = Properties<Roster>(title: "Roster") {
        Property("frame", \.frame).required()
        Property("names", \.names)
        Property("weights", \.weights)
        Property("stamp", \.stamp)
        Property("seal", \.seal)
    }
    var frame: CGRect
    var names: [String] = []
    var weights: [Double] = []
    var stamp: String?
    var seal: Bool?
    init(_ frame: CGRect) { self.frame = frame }
}

extension Roster {
    init() { self.init(.zero) }
}

struct RosterDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Roster>, in context: RenderContext) {}
}

/// A roster, and a rule: a stamp given to a roster that has none seals it, unless the script says
/// whether it is sealed.
let rosters = Contributor(id: "rosters") { registrar in
    registrar.shape(RosterDefinition()) { roster in
        roster.tool(label: "Roster", systemImage: "list.bullet", placing: roster.placement(size: CGSize(width: 100, height: 60)) { Roster() })
    }
    registrar.drawImplies { kind, before, settings, _ in
        guard kind == Roster.kind, settings["stamp"] != nil, before?.typed(as: Roster.self)?.props.stamp == nil else { return [:] }
        return ["seal": true]
    }
}

@MainActor private func roster(in editor: CanvasEditor) -> Roster? {
    editor.document.shapes.compactMap { $0.typed(as: Roster.self) }.last?.props
}

@MainActor let drawListTests = Suite("draw: lists of text and what attributes imply", [
    test("a quoted value for a list of text is a list of one item; several are JSON; a bare word is still refused") {
        let editor = try drawEditor([rosters])
        let one = try drawn(#"roster names: "Employee card""#, on: editor)
        expectEqual(rows(one).map { $0["did"] }, ["created"])
        expectEqual(roster(in: editor)?.names, ["Employee card"])
        _ = try drawn(#"roster names: ["Person", "Employee card"]"#, on: editor)
        expectEqual(roster(in: editor)?.names, ["Person", "Employee card"])
        let kinds = try run(["kinds"], on: editor).get().arrayValue ?? []
        let attributes = try require(kinds.first { $0["kind"] == "roster" }?["attributes"]?.objectValue)
        expectEqual(attributes["names"], "JSON [text]", "canvas kinds says a list is JSON; a quoted item is the short way")
        let bare = try refused(#"roster names: Person"#, on: editor)
        expectEqual(bare.reason, "invalid_value")
    },

    test("a quoted value for a list of anything but text is refused as it was, and a quoted empty text is a list of one empty text") {
        let editor = try drawEditor([rosters])
        let weights = try refused(#"roster weights: "3""#, on: editor)
        expectEqual(weights.reason, "invalid_value")
        expectEqual(editor.document.shapes.count, 0, "nothing drawn")
        _ = try drawn(#"roster names: """#, on: editor)
        expectEqual(roster(in: editor)?.names, [""])
    },

    test("a setting an attribute implies goes with it in the same step; the script's own say wins; nothing is implied by a script that sets nothing") {
        let editor = try drawEditor([rosters])
        let steps = editor.undoHistory.undoName
        _ = try drawn(#"roster stamp: "x""#, on: editor)
        var made = try require(roster(in: editor))
        expectEqual(made.seal, true)
        expectEqual(made.stamp, "x", "the script's own value stays")
        expect(editor.undoHistory.undoName != steps)
        editor.undo()
        expectEqual(editor.document.shapes.count, 0, "one step takes both")

        _ = try drawn(#"roster stamp: "x" seal: false"#, on: editor)
        made = try require(roster(in: editor))
        expectEqual(made.seal, false, "said")

        _ = try drawn(#"roster names: "a""#, on: editor)
        expectEqual(roster(in: editor)?.seal, nil, "a roster given no stamp is not sealed")
    },
])
