import Canvas
import SwiftUI

// MARK: Takeovers

/// What takes over the whole panel while it's active (Find's panel, its `FindPanelPlugin`): in place
/// of "No Selection" and the selection's panel, with the panel's environment, frame and width as
/// ever. The plugin whose view it is gives it (`registrar.detailTakeover`), so the
/// panel never learns what it is. A list, in plugin order: the first that's active shows.
public enum DetailTakeovers {}

extension DetailTakeovers: ExtensionPoint {
    public typealias Contribution = DetailTakeover
    public static var owner: PluginID { .detailPanel }
    public static func summary(of _: DetailTakeover, for _: ShapeTarget) -> String { "detail takeover" }
}

/// What `DetailTakeovers` stores: when it's active, what Escape does to it, and its view, made for a
/// panel as the panel is. Only the sugar makes one.
@MainActor
public struct DetailTakeover {
    let isActive: @MainActor (CanvasEditor) -> Bool
    let onEscape: @MainActor (CanvasEditor) -> Void
    let content: @MainActor (CanvasEditor, @escaping @MainActor () -> Void) -> AnyView
}

extension PluginRegistrar {
    /// A takeover of the panel: while `isActive` holds, `content` (handed the panel's editor and its
    /// `onExit`, which gives the keyboard back to the canvas, and following the editor by itself)
    /// shows in place of everything else.
    ///
    /// `isActive` is read in the panel's body, so it reads observable state (an `@Observable`
    /// service) and the panel redraws only when it flips. `onEscape` runs on Escape and ⌘. in the
    /// panel while the takeover is active, before the panel's `onExit` gives the keyboard back to
    /// the canvas (a text view holding keys, a list shown over its text, hears Escape before either):
    ///
    ///     registrar.detailTakeover(isActive: { $0.find?.isActive ?? false }, onEscape: { $0.find?.close() }) { editor, onExit in
    ///         FindPanel(editor: editor, onExit: onExit)
    ///     }
    public mutating func detailTakeover<Content: View>(
        isActive: @escaping @MainActor (CanvasEditor) -> Bool, onEscape: @escaping @MainActor (CanvasEditor) -> Void,
        @ViewBuilder content: @escaping @MainActor (_ editor: CanvasEditor, _ onExit: @escaping @MainActor () -> Void) -> Content
    ) {
        contribute(DetailTakeover(isActive: isActive, onEscape: onEscape, content: { AnyView(content($0, $1)) }), to: DetailTakeovers.self)
    }
}

extension Registry {
    /// The takeovers plugins gave, in plugin order.
    var detailTakeovers: [DetailTakeover] { contributions(to: DetailTakeovers.self).map(\.value) }

    /// The takeover that shows in an editor's panel: the first that's active, in plugin order. Whoever
    /// reads it observes what each `isActive` reads.
    func activeDetailTakeover(in editor: CanvasEditor) -> DetailTakeover? { detailTakeovers.first { $0.isActive(editor) } }
}

/// A takeover in a panel: its view made, for that panel's editor and `onExit`.
@MainActor
struct PlacedTakeover {
    let takeover: DetailTakeover
    let content: AnyView
}
