import Canvas
import CoreGraphics
import Ellipses
import Titles

/// A bridge: gives ellipses a title from outside, so neither Ellipses nor Titles knows about the
/// other. This module's two imports are the only edges between them in Package.swift. The title is
/// derived, not given: the ellipse's size, which its pill and its row in the table of contents show.
public struct EllipseTitlesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "ellipse-titles" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.title(Ellipse.self) { ellipse in
            "Ellipse, \(Int(ellipse.frame.width)) × \(Int(ellipse.frame.height))"
        }
    }
}
