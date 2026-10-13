import Canvas
import Connections
import Neighbors
import TestKit

// Arrows' lights for Neighbors (`ArrowLightsPlugin`): what the hovered shape points to and what points
// to it, each a query over `arrow` edges and what a stand-in stands for, and the arrows between. What they light on the
// shipped editor is CompositionTests' (NeighborsShippedTests).

@MainActor let arrowLightTests = Suite("Arrows' lights for Neighbors", [
    test("two lights, in order: what the hovered shape points to, then what points to it, each titled for its list, an arrow's own end among them") {
        let lights = try Registry(plugins: [NeighborsPlugin(), ArrowLightsPlugin()]).neighborLights
        expectEqual(lights.map(\.title), ["Points To", "Pointed To By"])
        expectEqual(lights.map { $0.query("#x") }, [":edge-from(#x, arrow|stands-for), :end-of(#x, arrow)",
                                                    ":edge-to(#x, arrow|stands-for), :start-of(#x, arrow)"])
        expect(lights.count == 2 && lights[0].color != lights[1].color, "a color each")
    },
    test("each light's arrows run between, lit with its shapes and never listed: the arrows an arrow starts or ends") {
        let lights = try Registry(plugins: [NeighborsPlugin(), ArrowLightsPlugin()]).neighborLights
        expectEqual(lights.map { $0.between?("#x") }, [":starts-at(#x, arrow)", ":ends-at(#x, arrow)"])
        expectEqual(lights.map { $0.lit("#x") }, [":edge-from(#x, arrow|stands-for), :end-of(#x, arrow), :starts-at(#x, arrow)",
                                                  ":edge-to(#x, arrow|stands-for), :start-of(#x, arrow), :ends-at(#x, arrow)"])
        expect(lights.allSatisfy { $0.caption == nil }, "no line under a shape it points to or is pointed to by")
    },
    test("ArrowLightsPlugin needs Neighbors, whose lights it adds to") {
        expectThrows(RegistryError.ownerNotInstalled(point: "NeighborLights", owner: .neighbors, contributor: .arrowLights)) {
            _ = try Registry(plugins: [ArrowLightsPlugin()])
        }
    },
])
