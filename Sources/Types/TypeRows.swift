import Canvas
import CoreGraphics

// What a kind that shows a type's rows lays itself out with. Declared here, provided by Types once a
// shape's rows are drawn: until then nothing answers, and every shape is as big as it stores.

/// The room a shape's rows take: what a kind that shows them lays itself out with.
public struct RowsExtent: Hashable, Sendable {
    /// The least width the rows read at.
    public var minimumWidth: CGFloat
    /// How tall they are, all of them, the fold included.
    public var height: CGFloat

    public init(minimumWidth: CGFloat, height: CGFloat) {
        self.minimumWidth = minimumWidth
        self.height = height
    }
}

public enum TypeRows {
    /// The room a shape's rows take, as the shape's layout input (`context.layoutInput`): nil for a
    /// shape with no rows.
    public static let extent = LayoutInputKey<RowsExtent>("type-rows")
}
