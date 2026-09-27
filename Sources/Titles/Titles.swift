import Canvas
import TableOfContents

/// Titles, as a plugin: what a shape is called, a trait any kind can opt into. Where a title comes
/// from is the kind's business: stored in its props, where someone names the shape (a note's
/// title), or derived from them (an ellipse's size). Any shape of a titled kind may have none. A
/// titled shape shows its title in a pill just outside its top-left corner, and its row in the
/// table of contents is called by it; `TitleHeader` renames it in the detail panel. The core never
/// learns what a title is.
extension PluginID {
    public static let titles: PluginID = "titles"
}

/// The extension point: which kinds have titles, what a shape's is, and whether the canvas shows it.
/// At most one per kind: two plugins titling the same kind is `RegistryError.conflict` at startup.
public enum ShapeTitles {}

extension ShapeTitles: KeyedExtensionPoint {
    public typealias Contribution = TitleContribution
    public static var owner: PluginID { .titles }
    public static func uniqueKeys(of _: TitleContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// What `ShapeTitles` stores for a kind: its shapes' titles, and whether the canvas shows them in a
/// pill. Only the sugar below makes one.
@MainActor
public struct TitleContribution {
    let title: @MainActor (AnyShapeRecord) -> String?
    let showsPill: Bool
}

// Sugar, so opting in is one line and never names the extension point.
extension ShapeRegistrar {
    /// Gives this kind a title: what `make` says a shape is called, if anything (nil or blank is
    /// none). Stored in the props (`note.title { $0.props.title }`), or derived from them
    /// (`label.title { $0.props.text }`). A titled shape shows it in a pill above its top-left
    /// corner, unless `pill` is false (for a kind that draws its own), and it names the shape's row
    /// in the table of contents, unless `contents` is false (for a kind whose row says more). To
    /// rename a stored title in the detail panel, put a `TitleHeader` in the kind's header.
    public mutating func title(pill: Bool = true, contents: Bool = true,
                               _ make: @escaping @MainActor (ShapeRecord<Definition.Props>) -> String?) {
        contribute(TitleContribution(title: { $0.typed(as: Definition.Props.self).flatMap(make) }, showsPill: pill), to: ShapeTitles.self)
        if contents { contentsTitle(make) }
    }
}

extension PluginRegistrar {
    /// A title for a kind another plugin registers (bridges), as `title` on a kind's own registrar.
    public mutating func title<P: ShapeProps>(_: P.Type, pill: Bool = true, contents: Bool = true,
                                              _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        contribute(TitleContribution(title: { $0.typed(as: P.self).flatMap(make) }, showsPill: pill), to: ShapeTitles.self, for: .kind(P.kind))
        if contents { contentsTitle(P.self, make) }
    }
}

extension Registry {
    /// What a shape is called; nil if its kind has no title, or its title is blank.
    public func title(of shape: AnyShapeRecord) -> String? {
        contributions(to: ShapeTitles.self, for: shape.kind).first?.title(shape).flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
    }
}

/// A horizontal any kind can opt into: a title, stored or derived, in a pill on the canvas and
/// naming the shape's row in the table of contents. The kind says what its shapes are called; this
/// plugin shows it, and `TitleHeader` renames it.
public struct TitlesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .titles }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.overlay(TitleOverlay())
    }
}
