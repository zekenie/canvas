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

// MARK: Bands

/// What shows above the panel's own content while it's active (the walk's band, Validation's): over a
/// takeover or the selection's panel, whichever of them shows, which go on under it. The plugin whose
/// view it is gives it (`registrar.detailBand`), so the panel never learns what it is. A list, in plugin
/// order: the first that's active shows. It holds the keyboard apart from what's under it: Escape in the
/// panel gives it the keyboard before it gives it back to the canvas.
public enum DetailBands {}

extension DetailBands: ExtensionPoint {
    public typealias Contribution = DetailBand
    public static var owner: PluginID { .detailPanel }
    public static func summary(of _: DetailBand, for _: ShapeTarget) -> String { "detail band" }
}

/// What `DetailBands` stores: when it's active, what ends it (⌘. in the panel, and hiding the
/// inspector), and its view, made for a panel as the panel is. Only the sugar makes one.
@MainActor
public struct DetailBand {
    let isActive: @MainActor (CanvasEditor) -> Bool
    let onCancel: @MainActor (CanvasEditor) -> Void
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

    /// A band over the panel: while `isActive` holds, `content` (handed the panel's editor and its
    /// `onExit`, as a takeover's is) shows above whatever the panel shows, a takeover included.
    ///
    /// `isActive` is read in the panel's body, so it reads observable state and the panel redraws
    /// only when it flips. `onCancel` ends what the band stands for, and runs on ⌘. in the panel (after
    /// the takeover's `onEscape`, before the panel's `onExit`) and when the person hides the
    /// inspector; Escape does not run it: Escape gives the band the keyboard, and from the band it goes
    /// to the canvas, the band staying. The band keeps the inspector requested while it's active, as a
    /// takeover does:
    ///
    ///     registrar.detailBand(isActive: { $0.issueWalk?.isRunning ?? false }, onCancel: { $0.issueWalk?.end() }) { editor, _ in
    ///         IssueBand(editor: editor)
    ///     }
    public mutating func detailBand<Content: View>(
        isActive: @escaping @MainActor (CanvasEditor) -> Bool, onCancel: @escaping @MainActor (CanvasEditor) -> Void,
        @ViewBuilder content: @escaping @MainActor (_ editor: CanvasEditor, _ onExit: @escaping @MainActor () -> Void) -> Content
    ) {
        contribute(DetailBand(isActive: isActive, onCancel: onCancel, content: { AnyView(content($0, $1)) }), to: DetailBands.self)
    }
}

extension Registry {
    /// The takeovers plugins gave, in plugin order.
    var detailTakeovers: [DetailTakeover] { contributions(to: DetailTakeovers.self).map(\.value) }

    /// The takeover that shows in an editor's panel: the first that's active, in plugin order. Whoever
    /// reads it observes what each `isActive` reads.
    func activeDetailTakeover(in editor: CanvasEditor) -> DetailTakeover? { detailTakeovers.first { $0.isActive(editor) } }

    /// The bands plugins gave, in plugin order.
    var detailBands: [DetailBand] { contributions(to: DetailBands.self).map(\.value) }

    /// The band that shows in an editor's panel: the first that's active, in plugin order. Whoever
    /// reads it observes what each `isActive` reads.
    func activeDetailBand(in editor: CanvasEditor) -> DetailBand? { detailBands.first { $0.isActive(editor) } }
}

/// A takeover in a panel: its view made, for that panel's editor and `onExit`.
@MainActor
struct PlacedTakeover {
    let takeover: DetailTakeover
    let content: AnyView
}

/// A band in a panel: its view made, for that panel's editor and `onExit`.
@MainActor
struct PlacedBand {
    /// Its place in the list: two bands are two views, not one that changes.
    let index: Int
    let band: DetailBand
    let content: AnyView
}
