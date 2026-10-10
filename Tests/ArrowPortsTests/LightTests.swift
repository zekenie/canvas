import Canvas
import Connections
import Neighbors
import TestKit

// Arrows' lights for Neighbors (`ArrowLightsPlugin`): what the hovered shape points to and what points
// to it, each a query over `arrow` edges and what a stand-in stands for. What they light on the
// shipped editor is CompositionTests' (NeighborsShippedTests).

@MainActor let arrowLightTests = Suite("Arrows' lights for Neighbors", [
    test("two lights, in order: what the hovered shape points to, then what points to it, the arrows between and an arrow's own ends with them") {
        let lights = try Registry(plugins: [NeighborsPlugin(), ArrowLightsPlugin()]).neighborLights
        expectEqual(lights.map { $0.query("#x") }, [":edge-from(#x, arrow|stands-for), :starts-at(#x, arrow), :end-of(#x, arrow)",
                                                    ":edge-to(#x, arrow|stands-for), :ends-at(#x, arrow), :start-of(#x, arrow)"])
        expect(lights.count == 2 && lights[0].color != lights[1].color, "a color each")
    },
    test("ArrowLightsPlugin needs Neighbors, whose lights it adds to") {
        expectThrows(RegistryError.ownerNotInstalled(point: "NeighborLights", owner: .neighbors, contributor: .arrowLights)) {
            _ = try Registry(plugins: [ArrowLightsPlugin()])
        }
    },
])
