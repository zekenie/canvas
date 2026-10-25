import Canvas
import Neighbors
import TestKit
import Topology
import Types

// Types' lights for Neighbors (`TypeLightsPlugin`): what is of the hovered type, queries over `is-a` edges.
// What it lights and lists on the shipped editor is CompositionTests' (NeighborsShippedTests,
// ConnectionsShippedTests).

@MainActor let typeLightTests = Suite("Types' light for Neighbors", [
    test("two lights, Instances and Subtypes: what is of the hovered type however far while it is a type, the shapes that are no type and the types built on it, in one pink, nothing between and no line under a row") {
        let lights = try Registry(plugins: [NeighborsPlugin(), TypeLightsPlugin()]).neighborLights
        expectEqual(lights.map(\.title), ["Instances", "Subtypes"])
        let (schema, isA) = (TypeSchemaProperty.key.rawValue, IsAEdge.id.rawValue)
        expectEqual(lights.map { $0.query("#x") }, [":\(isA)(#x[\(schema)]):not([\(schema)])", "[\(schema)]:\(isA)(#x[\(schema)])"])
        expectEqual(lights.map { $0.lit("#x") }, [":is-a(#x[schema]):not([schema])", "[schema]:is-a(#x[schema])"],
                    "the edge type's id is is-a, the property's key schema")
        expect(lights.allSatisfy { $0.between == nil && $0.caption == nil })
        expectEqual(lights[0].color, lights[1].color, "a shape is one or the other: one pink")
    },
    test("both are shown with ⌥ held, as what points to a shape is (what is of a type has an is-a edge to it), which the Keyboard Shortcuts window says") {
        let registry = try Registry(plugins: [NeighborsPlugin(), TypeLightsPlugin()])
        expectEqual(registry.neighborLights.map(\.keys), [.option, .option])
        expectEqual(registry.keyboardHelp, [KeyboardHelpRow(keys: ["⌥ Hover a Type"], title: "Show Its Instances and Subtypes", place: .pointer)])
    },
    test("TypeLightsPlugin needs Neighbors, whose lights it adds to") {
        expectThrows(RegistryError.ownerNotInstalled(point: "NeighborLights", owner: .neighbors, contributor: .typeLights)) {
            _ = try Registry(plugins: [TypeLightsPlugin()])
        }
    },
])
