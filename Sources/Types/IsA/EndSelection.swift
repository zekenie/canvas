import Canvas
import CoreGraphics
import Selection

// The pair: the two arrows at a relationship type are one line through its pill, so for the select tool the line is the type.
// A point on either half is the relationship type (hover, a click, a right-click), and its two halves are outlined with it,
// selected or hovered. Once the type is selected a press on a half is that half's (so it can be re-aimed, and a double-click
// opens its row), and so is a press on a half that is selected itself. Nothing of it is stored.

extension CanvasEditor {
    /// The relationship type a point on one of its end arrows stands for, for the select tool: nil where the front-most shape
    /// `include` accepts under the point (whatever its kind) is no end, where the type is already selected (the press is the half's) or where
    /// the half is, or the type cannot be selected. One lookup of the shape under the point, asked as the pointer moves.
    func relationshipTypeHit(at point: CGPoint, where include: (AnyShapeRecord) -> Bool) -> ShapeID? {
        guard let relationships, relationships.isActive else { return nil }
        // The front-most shape the select tool would press there: a note lying over the line is that note's.
        guard let under = shape(at: point, where: include),
              let hub = relationships.end(under)?.type, !isSelected(hub), !isSelected(under),
              let record = document[hub], include(record) else { return nil }
        return hub
    }

    /// What a relationship type outlines besides itself while it is selected or hovered: its end arrows.
    var relationshipEndOutlines: Outlines {
        guard let relationships, relationships.isActive else { return Outlines() }
        // The selected relationship types, read from whichever is smaller, the selection or the types with ends: a frame of a large
        // selection costs the file's relationship types, not the selection.
        let hubs = relationships.graph.ends.sides
        let selectedHubs = selectedShapeIDs.count <= hubs.count ? selectedShapeIDs.filter { hubs[$0] != nil } : hubs.keys.filter(isSelected)
        var full: [ShapeID] = []
        for id in selectedHubs { full.append(contentsOf: relationships.endArrows(of: id)) }
        var faint: [ShapeID] = []
        if session == nil, let hovered { faint = Array(relationships.endArrows(of: hovered)) }
        return Outlines(shapes: full, faintShapes: faint)
    }
}

@MainActor
func registerEndSelection(into registrar: inout PluginRegistrar) {
    registrar.decorationHits { editor, point, include in editor.relationshipTypeHit(at: point, where: include) }
    registrar.outlines { $0.relationshipEndOutlines }
}
