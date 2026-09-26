import AppKit
@_spi(Host) import Canvas

/// A kind whose only capability is declared in LinkerGuardConformance.swift, a file nothing refers
/// to by name. If static archives dropped that file, `definition is any Editable` would quietly be
/// false. The build's -wmo (one object file per module) and -force_load (link every object) each
/// keep it on their own, so the RegistryTests check fails only once both are gone.
public struct Sealed: BoxShapeProps {
    public static let kind: ShapeKind = "sealed"
    public var frame: CGRect
    public init(_ frame: CGRect) { self.frame = frame }
}

struct SealedDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Sealed>, in context: RenderContext) {}
}

public struct LinkerGuardPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "linker-guard" }
    public func register(into registrar: inout PluginRegistrar) { registrar.shape(SealedDefinition()) }
}
