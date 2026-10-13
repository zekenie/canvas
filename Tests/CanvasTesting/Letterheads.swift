import Canvas

/// A file property for tests: what the file is headed with, nothing ("") until it's set. What core
/// and host tests keep on a file as a whole, so they never depend on a plugin that ships one.
public enum Letterhead {}

extension Letterhead: FileProperty {
    public static let key: PropertyKey = "letterhead"
    public static var defaultValue: String { "" }
}

/// Declares `Letterhead`. Apart from `FixturesPlugin`, so the registry reports tests pin don't change.
public struct LetterheadPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "letterhead" }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(file: Letterhead.self)
    }
}
