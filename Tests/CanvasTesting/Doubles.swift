import AppKit
import Canvas

/// Set once something happened (an Observation `onChange`, say).
public final class Flag: @unchecked Sendable {
    public private(set) var isSet = false
    public init() {}
    public func set() { isSet = true }
}

/// A tool that does nothing when pressed.
public final class NoTool {
    public init() {}
}

extension NoTool: Tool {
    public func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {}
}

/// A box kind whose definition states only `render` and `geometry`: a diamond inside its frame.
public struct Diamond: BoxShapeProps {
    public static let kind: ShapeKind = "diamond"
    public static let properties = Properties<Diamond> {
        Property("frame", \.frame).required()
    }
    public var frame: CGRect
    public init(_ frame: CGRect) { self.frame = frame }
}

extension Diamond {
    public init() { self.init(.zero) }
}

public struct DiamondDefinition {
    public init() {}
}

extension DiamondDefinition: ShapeDefinition {
    public func render(_ shape: ShapeRecord<Diamond>, in context: RenderContext) {}
    public func geometry(of shape: ShapeRecord<Diamond>, in context: ShapeContext) -> ShapeGeometry {
        let f = shape.frame
        return ShapeGeometry(outline: [CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.maxX, y: f.midY),
                                       CGPoint(x: f.midX, y: f.maxY), CGPoint(x: f.minX, y: f.midY)], bounds: f)
    }
}

/// A session that does nothing but hold the press.
public final class IdleSession {
    public init() {}
}

extension IdleSession: Session {
    public func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
}

/// A drag that reshapes a shape, as far as outlines go: while it runs, plugins' outlines hide.
public final class OutlineHidingSession {
    public init() {}
}

extension OutlineHidingSession: Session {
    public var hidesOutlines: Bool { true }
    public func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
}

/// Boxes that draw nothing and take every default, for a test's own plugin.
public struct BoxDefinitionForTests {
    public init() {}
}

extension BoxDefinitionForTests: ShapeDefinition {
    public func render(_ shape: ShapeRecord<Box>, in context: RenderContext) {}
}

/// Discs that draw nothing and take every default: their geometry is their frame.
public struct DiscDefinitionForTests {
    public init() {}
}

extension DiscDefinitionForTests: ShapeDefinition {
    public func render(_ shape: ShapeRecord<Disc>, in context: RenderContext) {}
}

/// A "disc" place tool, placing 40 × 40 discs that follow the pointer.
@MainActor public func discTools() -> Contributor {
    Contributor(id: "discs") { r in
        r.shape(DiscDefinitionForTests()) { disc in
            disc.tool(label: "Disc", systemImage: "circle", placing: disc.placement(size: CGSize(width: 40, height: 40)) { Disc(.zero) })
        }
    }
}
