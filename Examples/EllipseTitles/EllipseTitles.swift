import Canvas
import CoreGraphics
import DetailPanel
import Ellipses
import Titles

/// A bridge: gives ellipses a title from outside, so neither Ellipses nor Titles knows about the
/// other. This module's imports are the only edges between them in Package.swift. An ellipse can
/// be named, as a note can (the title Titles keeps, `TitleProperty`, which it opts ellipses into),
/// and one nobody named is called by its size instead ("Ellipse, 200 × 140"): what its pill and its
/// row in the table of contents show. The detail panel's header renames it, or clears the name,
/// with the size the name it goes back to.
public struct EllipseTitlesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "ellipse-titles" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.optIn(Ellipse.self, to: TitleProperty.self)
        registrar.title(Ellipse.self) { ellipse in
            TitleProperty.folded(ellipse[TitleProperty.self]) ?? Self.sized(ellipse.props)
        }
        registrar.details(Ellipse.self, header: Self.header) {}
    }

    /// The panel's header: the name, renamed in place, with what it's called by its size while
    /// nobody's named it.
    static func header(_ ellipse: ShapeBinding<Ellipse>) -> TitleHeader {
        TitleHeader(ellipse, placeholder: sized(ellipse.wrappedValue))
    }

    /// What an ellipse nobody named is called: "Ellipse, 200 × 140".
    static func sized(_ ellipse: Ellipse) -> String {
        "Ellipse, \(Int(ellipse.frame.width)) × \(Int(ellipse.frame.height))"
    }
}
