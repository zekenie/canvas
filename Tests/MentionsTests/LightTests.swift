import AppKit
import Canvas
import CanvasTesting
import Mentions
import Neighbors
import TestKit

// Mentions' lights for Neighbors (`MentionLightsPlugin`): what the hovered shape's text mentions and
// what mentions it, each a query over `mention` edges, titled for the panel's lists, and a line under
// each mentioner in the list of what mentions it. What they light on the shipped editor is
// CompositionTests' (NeighborsShippedTests).

@MainActor let mentionLightTests = Suite("Mentions' lights for Neighbors", [
    test("two lights, in order: what the hovered shape mentions, then what mentions it; titled for the panel, with no arrow between") {
        let lights = try Registry(plugins: [NeighborsPlugin(), MentionLightsPlugin()]).neighborLights
        expectEqual(lights.map { $0.query("#x") }, [":edge-from(#x, mention)", ":edge-to(#x, mention)"])
        expect(lights.count == 2 && lights[0].color != lights[1].color, "a color each")
        expectEqual(lights.map(\.title), ["Mentions", "Mentioned By"])
        expect(lights.allSatisfy { $0.between == nil }, "no shape runs between")
        expect(lights[0].caption == nil, "what it mentions gets no line under its name")
    },
    test("both are shown with ⌃⌥ held, which the Keyboard Shortcuts window says once") {
        let registry = try Registry(plugins: [NeighborsPlugin(), MentionLightsPlugin()])
        expectEqual(registry.neighborLights.map(\.keys), [[.control, .option], [.control, .option]])
        expectEqual(registry.keyboardHelp, [KeyboardHelpRow(keys: ["⌃⌥ Hover"], title: "Show Mentions", place: .pointer)])
    },
    test("what mentions a shape is listed under the mentioner's text around its mention, the names as they show now") {
        let h = try mentionHarness([NeighborsPlugin(), MentionLightsPlugin()])
        let target = h.editor.add(Plate(CGRect(x: 400, y: 0, width: 120, height: 80)), titled: "Groceries")
        let mentioner = h.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200),
                                  text: MentionText([.text("Buy "), .mention(target, label: "Groceries"), .text(" today")])))
        let caption = try require(h.editor.registry.neighborLights[1].caption)
        expectEqual(caption(h.editor, PartAddress(target), mentioner), "Buy @Groceries today")
        expectEqual(caption(h.editor, PartAddress(target), mentioner), h.editor.mentions?.quote(of: mentioner, around: target))
        expectEqual(caption(h.editor, PartAddress(target), target), nil, "a shape whose text doesn't mention it gets no line")
    },
    test("MentionLightsPlugin needs Neighbors, whose lights it adds to") {
        expectThrows(RegistryError.ownerNotInstalled(point: "NeighborLights", owner: .neighbors, contributor: .mentionLights)) {
            _ = try Registry(plugins: [MentionLightsPlugin()])
        }
    },
])
