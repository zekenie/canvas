import Canvas

// What VoiceOver says of what a shape is, after its kind: the types it is ("Checkout, Note, Feature"), and of a type that it is one
// ("Person, Note, Type"; a relationship type "owns, Note, Relationship Type"). Said through the core's point (`accessibility`), so
// the chips above a shape, which a sighted person reads, are heard with the shape.

@MainActor
func registerTypeAccessibility(into registrar: inout PluginRegistrar) {
    registrar.forShapes(holding: IsAProperty.self) { typeable in
        typeable.accessibility { record, editor in
            guard let links = record[IsAProperty.self], !links.isEmpty, let types = editor.types else { return nil }
            return AccessibleTraits(labelParts: links.map { TypesStyle.menuName(types.name(of: $0)) })
        }
    }
    registrar.forShapes(holding: TypeSchemaProperty.self) { typeKinds in
        typeKinds.accessibility { record, _ in
            guard record[TypeSchemaProperty.self] != nil else { return nil }
            return AccessibleTraits(labelParts: [record[RelationshipProperty.self] == true ? TypesStyle.relationshipTypeChoice : TypesStyle.typeChoice])
        }
    }
}
