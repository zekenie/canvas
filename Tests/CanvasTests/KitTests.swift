@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// Kits (Kits.swift, CanvasEditor+Kits.swift): a plugin joins a kit, and while the kit is off in a file what it
// gives a point a kit switches is gone there (its tools, its commands, its Insert items), while what else it
// gives stays (its kinds). Which kits are on is the core's file value, `kits`. CanvasTesting's `Workshop` is the
// kit and `WorkshopPlugin` its plugin (planks, the Plank tool, Edit ▸ Carve).

/// A point of the tests' own that a kit switches, and one it doesn't: what a horizontal reads through the editor.
private enum Pegs {}
extension Pegs: ExtensionPoint, KitSwitched {
    typealias Contribution = String
    static var owner: PluginID { .core }
}

private enum Nails {}
extension Nails: ExtensionPoint {
    typealias Contribution = String
    static var owner: PluginID { .core }
}

/// A peg and a nail for every kind and one for planks, from a plugin in `kit` (none: in no kit).
@MainActor private func pegs(_ id: PluginID, kit: (any Kit.Type)?) -> Contributor {
    Contributor(id: id) { r in
        if let kit { r.join(kit) }
        r.contribute("\(id) peg", to: Pegs.self)
        r.contribute("\(id) plank peg", to: Pegs.self, for: .kind(Plank.kind))
        r.contribute("\(id) nail", to: Nails.self)
    }
}

@MainActor private func workshop(_ log: WorkshopLog = WorkshopLog(), _ more: [any CanvasPlugin] = [], file: CanvasFile = CanvasFile()) throws -> EditorHarness {
    let h = try EditorHarness(plugins: [FixturesPlugin(), WorkshopPlugin(log: log)] + more, file: file)
    h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return h
}

private let plankTool = ToolID(placing: Plank.kind)

/// A file of one box, with these kits on.
private func file(kits: [KitID]) -> CanvasFile {
    var file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 10, height: 10))))]))
    file[KitsOn.self] = kits
    return file
}

/// Why the registry refuses the list; nil if it doesn't.
@MainActor private func refusal(_ plugins: [any CanvasPlugin]) -> String? {
    do {
        _ = try Registry(plugins: plugins)
        return nil
    } catch {
        return "\(error)"
    }
}

@MainActor let kitTests = Suite("Kits", [
    test("a plugin joins a kit: the registry has the kit, its plugin, its tools and its commands; the report says it") {
        let registry = try Registry(plugins: [FixturesPlugin(), WorkshopPlugin(), pegs("loose", kit: nil)])
        expectEqual(registry.kits.map(\.id), ["workshop"])
        expectEqual(registry.kits.map(\.title), ["Workshop"])
        expectEqual(registry.kit(of: "workshop"), "workshop")
        expectEqual(registry.kit(of: "loose"), nil, "a plugin in no kit")
        expectEqual(registry.kit(ofTool: plankTool), "workshop")
        expectEqual(registry.kit(ofTool: .hand), nil)
        expectEqual(registry.kit(ofCommand: .carve), "workshop")
        expectEqual(registry.kit(ofCommand: .insert(plankTool)), "workshop", "the Insert item of a kit's tool is the kit's")
        expectEqual(registry.kit(ofCommand: .kit("workshop")), nil, "a kit's own item in File ▸ Kits is no kit's")
        expectEqual(registry.plugins(in: "workshop"), ["workshop"])
        let lines = registry.report.split(separator: "\n")
        expect(lines.first { $0.hasPrefix("core ") }?.hasSuffix("file property kits · command kit:workshop in FileMenu.KitList") == true,
               "the core declares the file value and the kit's item once a plugin joins a kit")
        expect(lines.first { $0.hasPrefix("workshop ") }?.contains("kit workshop · shape plank · tool plank · command insert:plank in KitShapes<Workshop> · command carve in WorkshopSection") == true,
               "the member's line says its kit first, and its tool's Insert item in the kit's submenu")
    },
    test("a list in which no plugin joins a kit has no kits, no file value and no Kits item, and its report is as it was") {
        let registry = try Registry(plugins: [FixturesPlugin(), WorkshopPlugin(kit: nil)])
        expectEqual(registry.kits.map(\.id), [])
        expect(!registry.declaredFileProperties.contains(KitsOn.key))
        expect(!registry.report.contains("kit"), "nothing of kits in the report")
        expectEqual(registry.menuBarCommands.first { $0.command == .insert(plankTool) }?.menu.description, "Insert", "a tool's item in Insert itself")
    },
    test("the registry refuses a plugin in two kits, a kit joined twice, two kits of one id and two of one title") {
        expectEqual(refusal([Contributor(id: "both") { $0.join(Workshop.self); $0.join(Studio.self) }]),
                    "KitMemberships: both joins two kits, workshop and studio; a plugin is in one kit at most")
        expectEqual(refusal([Contributor(id: "again") { $0.join(Workshop.self); $0.join(Workshop.self) }]),
                    "KitMemberships: again joins workshop twice")
        expectEqual(refusal([Contributor(id: "a") { $0.join(Workshop.self) }, Contributor(id: "b") { $0.join(Lookalike.self) }]),
                    "KitMemberships: two kits are called workshop: CanvasTesting.Workshop and CanvasTests.Lookalike")
        expectEqual(refusal([Contributor(id: "a") { $0.join(Workshop.self) }, Contributor(id: "b") { $0.join(Namesake.self) }]),
                    "KitMemberships: kits workshop and namesake are both titled Workshop")
    },
    test("every kit is off in a new file: its tool isn't enabled, its commands aren't claimed, its Insert item goes, and its kind stays") {
        let log = WorkshopLog()
        let h = try workshop(log)
        expectEqual(h.editor.kits, [])
        expect(!h.editor.isOn(Workshop.self))
        expect(!h.editor.isToolEnabled(plankTool), "the kit's tool")
        h.editor.setTool(plankTool)
        expectEqual(h.editor.currentToolID, .hand, "setTool refuses it")
        expect(!h.editor.claims(.carve) && !h.editor.canPerform(.carve) && !h.editor.perform(.carve), "the kit's command")
        expectEqual(log.carved, 0)
        expect(!h.editor.claims(.insert(plankTool)) && !h.editor.perform(.insert(plankTool)), "the kit's Insert item")
        expect(!h.editor.attempt(.carve, on: []), "nor is it tried")
        expect(h.editor.claims(.kit("workshop")) && h.editor.isChecked(.kit("workshop")) == false, "File ▸ Kits ▸ Workshop is there, unchecked")
        expect(h.editor.registry.definition(for: Plank.kind) != nil, "the kind is the registry's whatever the file says")
    },
    test("Turn On Workshop is one undo step: the tool, the commands and the Insert item come; undone they go, redone they come again") {
        let log = WorkshopLog()
        let h = try workshop(log)
        expect(h.editor.perform(.kit("workshop")))
        expectEqual(h.editor.kits, ["workshop"])
        expectEqual(h.editor.undoHistory.undoName, "Turn On Workshop")
        expectEqual(h.editor.isChecked(.kit("workshop")), true)
        expect(h.editor.isToolEnabled(plankTool))
        expect(h.editor.perform(.carve))
        expectEqual(log.carved, 1)
        expect(h.editor.perform(.insert(plankTool)))
        expectEqual(h.editor.document.shapes.map(\.kind), [Plank.kind], "Insert ▸ Workshop ▸ Plank put one down")
        h.editor.undo()
        h.editor.undo()
        expectEqual(h.editor.kits, [], "the toggle undone")
        expect(!h.editor.isToolEnabled(plankTool) && !h.editor.claims(.carve))
        h.editor.redo()
        expectEqual(h.editor.kits, ["workshop"])
        expect(h.editor.isToolEnabled(plankTool) && h.editor.claims(.carve))
        h.editor.turn(kit: "workshop", on: false)
        expectEqual(h.editor.undoHistory.undoName, "Turn Off Workshop")
        expectEqual(h.editor.kits, [])
        h.editor.turn(kit: "workshop", on: false)
        expectEqual(h.editor.undoHistory.undoName, "Turn Off Workshop", "turning off what's off is no step")
        h.editor.turn(kit: "nowhere", on: true)
        expectEqual(h.editor.kits, [], "nor is a kit no plugin joins")
    },
    test("a tool in use whose kit goes off gives way to the default tool") {
        let h = try workshop()
        h.editor.turn(Workshop.self, on: true)
        h.editor.setTool(plankTool)
        expectEqual(h.editor.currentToolID, plankTool)
        h.editor.undo()
        expectEqual(h.editor.currentToolID, .hand, "the default tool back as the kit went off")
    },
    test("shapes drawn with a kit stay while it's off: drawn, moved, changed and deleted as any") {
        let h = try workshop()
        h.editor.turn(Workshop.self, on: true)
        h.editor.perform(.insert(plankTool))
        let plank = try require(h.editor.document.shapes.first?.id)
        h.editor.turn(Workshop.self, on: false)
        expectEqual(h.editor.document.shapes.map(\.id), [plank], "still on the board")
        let before = try require(h.editor.document[plank]?.box)
        h.editor.transact("Move") { $0.translate([plank], by: CGPoint(x: 10, y: 0)) }
        expectEqual(h.editor.document[plank]?.box?.origin.x, before.origin.x + 10, "moved")
        h.editor.transact("Delete") { $0.delete([plank]) }
        expectEqual(h.editor.document.shapes.count, 0, "deleted")
        h.editor.undo()
        expectEqual(h.editor.document.shapes.map(\.id), [plank], "and back")
    },
    test("a switched point read through the editor leaves out an off kit's plugins; the registry's has every one; a point a kit doesn't switch, every one") {
        let h = try workshop(WorkshopLog(), [pegs("studio-pegs", kit: Studio.self), pegs("loose", kit: nil)])
        expectEqual(h.editor.contributions(to: Pegs.self).map(\.value), ["loose peg", "loose plank peg"], "every kit off")
        expectEqual(h.editor.contributions(to: Pegs.self, for: Plank.kind), ["loose plank peg", "loose peg"])
        expectEqual(h.editor.contributions(to: Pegs.self, reaching: Box.kind).map(\.value), ["loose peg"])
        expectEqual(h.editor.registry.contributions(to: Pegs.self).count, 4, "the registry holds them all")
        expectEqual(h.editor.registry.contributions(to: Nails.self).map(\.value), ["studio-pegs nail", "loose nail"])
        h.editor.turn(Studio.self, on: true)
        expectEqual(h.editor.contributions(to: Pegs.self).map(\.value), ["studio-pegs peg", "studio-pegs plank peg", "loose peg", "loose plank peg"],
                    "the studio on")
        expectEqual(h.editor.contributions(to: Pegs.self, for: Plank.kind), ["studio-pegs plank peg", "loose plank peg", "studio-pegs peg", "loose peg"])
        h.editor.turn(Workshop.self, on: true)
        expectEqual(h.editor.contributions(to: Pegs.self).count, 4, "every kit on")
    },
    test("the file keeps which kits are on, sorted; one this app has no kit for stays and is written back") {
        let h = try workshop(WorkshopLog(), [pegs("studio-pegs", kit: Studio.self)], file: file(kits: ["music"]))
        expectEqual(h.editor.kits, [], "music is no kit here")
        h.editor.turn(Workshop.self, on: true)
        h.editor.turn(Studio.self, on: true)
        expectEqual(h.file[KitsOn.self], ["music", "studio", "workshop"])
        expectEqual(h.editor.kits, ["studio", "workshop"])
        h.editor.turn(Workshop.self, on: false)
        h.editor.turn(Studio.self, on: false)
        expectEqual(h.file[KitsOn.self], ["music"], "what this app doesn't know is kept")
    },
    test("a file with every kit off is written as it always was; with one on, its value in the envelope at format 6, read back") {
        let registry = try Registry(plugins: [FixturesPlugin(), WorkshopPlugin()])
        let codec = BoardCodec(registry: registry)
        let off = file(kits: [])
        expect(!String(decoding: try codec.encode(off), as: UTF8.self).contains("\"values\""), "no values with every kit off")
        let on = file(kits: ["workshop"])
        let written = try JSONDecoder().decode(JSONValue.self, from: codec.encode(on))
        expectEqual(written["format"], 6)
        expectEqual(written["values"], ["kits": ["v": 0, "value": ["workshop"]]])
        expectEqual(try codec.decode(codec.encode(on)).file[KitsOn.self], ["workshop"], "read back")
    },
    test("a file put in place takes its kits with it, and a tool of one it turns off gives way") {
        let h = try workshop()
        h.editor.replaceFile(with: file(kits: ["workshop"]))
        expectEqual(h.editor.kits, ["workshop"])
        h.editor.setTool(plankTool)
        h.editor.replaceFile(with: file(kits: []))
        expectEqual(h.editor.kits, [])
        expectEqual(h.editor.currentToolID, .hand)
    },
    test("an editor opened on a file with a kit on has it on from the start") {
        let h = try workshop(file: file(kits: ["workshop"]))
        expectEqual(h.editor.kits, ["workshop"])
        expect(h.editor.isToolEnabled(plankTool))
    },
    test("the Keyboard Shortcuts window's hints leave out an off kit's") {
        let hints = Contributor(id: "hints") { r in
            r.join(Workshop.self)
            r.keyHint("⌥ Drag a Plank", "Split It", while: .pointer)
        }
        let registry = try Registry(plugins: [FixturesPlugin(), hints, Contributor(id: "loose") { $0.keyHint("⇧ Drag", "Square It", while: .pointer) }])
        expectEqual(registry.keyboardHelp(kitsOn: []).map(\.title), ["Square It"])
        expectEqual(registry.keyboardHelp(kitsOn: ["workshop"]).map(\.title), ["Split It", "Square It"])
        expectEqual(registry.keyboardHelp.map(\.title), ["Split It", "Square It"], "every kit's, read off the registry")
    },
])

/// Another kit that says it is the workshop.
enum Lookalike {}
extension Lookalike: Kit {
    static let id: KitID = "workshop"
    static var title: String { "Lookalike" }
}

/// Another kit by the workshop's title.
enum Namesake {}
extension Namesake: Kit {
    static let id: KitID = "namesake"
    static var title: String { "Workshop" }
}
