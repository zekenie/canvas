import Canvas
import Mentions
import Neighbors
import TestKit

// Mentions' lights for Neighbors (`MentionLightsPlugin`): what the hovered shape's text mentions and
// what mentions it, each a query over `mention` edges. What they light on the shipped editor is
// CompositionTests' (NeighborsShippedTests).

@MainActor let mentionLightTests = Suite("Mentions' lights for Neighbors", [
    test("two lights, in order: what the hovered shape mentions, then what mentions it") {
        let lights = try Registry(plugins: [NeighborsPlugin(), MentionLightsPlugin()]).neighborLights
        expectEqual(lights.map { $0.query("#x") }, [":edge-from(#x, mention)", ":edge-to(#x, mention)"])
        expect(lights.count == 2 && lights[0].color != lights[1].color, "a color each")
    },
    test("MentionLightsPlugin needs Neighbors, whose lights it adds to") {
        expectThrows(RegistryError.ownerNotInstalled(point: "NeighborLights", owner: .neighbors, contributor: .mentionLights)) {
            _ = try Registry(plugins: [MentionLightsPlugin()])
        }
    },
])
