import Canvas
import Neighbors
import TestKit
import Topology
import Types

// Types' light for Neighbors (`TypeLightsPlugin`): what is of the hovered type, a query over `is-a` edges.
// What it lights and lists on the shipped editor is CompositionTests' (NeighborsShippedTests,
// ConnectionsShippedTests).

@MainActor let typeLightTests = Suite("Types' light for Neighbors", [
    test("one light, Instances: the shapes with an is-a edge to the hovered one while it is a type, one hop, nothing between and no line under a row") {
        let lights = try Registry(plugins: [NeighborsPlugin(), TypeLightsPlugin()]).neighborLights
        expectEqual(lights.map(\.title), ["Instances"])
        expectEqual(lights.map { $0.query("#x") }, [":edge-to(#x[\(TypeSchemaProperty.key.rawValue)], \(IsAEdge.id.rawValue))"])
        expectEqual(lights.map { $0.lit("#x") }, [":edge-to(#x[schema], is-a)"], "the edge type's id is is-a, the property's key schema")
        expect(lights.allSatisfy { $0.between == nil && $0.caption == nil })
    },
    test("TypeLightsPlugin needs Neighbors, whose lights it adds to") {
        expectThrows(RegistryError.ownerNotInstalled(point: "NeighborLights", owner: .neighbors, contributor: .typeLights)) {
            _ = try Registry(plugins: [TypeLightsPlugin()])
        }
    },
])
