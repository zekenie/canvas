import Canvas
import SwiftUI

// MARK: The overview

/// What the panel shows where it has no one shape to show: in place of "No Selection", and under
/// the header when several shapes are selected (as data-canvas's details panel shows its table of
/// contents); and whatever is selected while it holds the keyboard (`holdsKeyboard`: the table of
/// contents walked by keys). The plugin whose view it is gives it (`registrar.detailOverview`: the
/// table of contents', its `ContentsOverviewPlugin`), so the panel never learns what it is. At most
/// one: two are `RegistryError.conflict` at startup.
public enum DetailOverviews {}

extension DetailOverviews: KeyedExtensionPoint {
    public typealias Contribution = DetailOverview
    public static var owner: PluginID { .detailPanel }
    public static func uniqueKeys(of _: DetailOverview, for _: ShapeTarget) -> [AnyHashable] { ["overview"] }
    public static func summary(of _: DetailOverview, for _: ShapeTarget) -> String { "detail overview" }
}

/// What `DetailOverviews` stores: whether it holds the keyboard, and the view, made for a panel as
/// the panel is. Only the sugar makes one.
@MainActor
public struct DetailOverview {
    let holdsKeyboard: @MainActor (CanvasEditor) -> Bool
    let content: @MainActor (CanvasEditor, @escaping @MainActor () -> Void) -> AnyView
}

// MARK: Takeovers

/// What takes over the whole panel while it's active (Find's panel, its `FindPanelPlugin`): in place
/// of "No Selection", the selection's panel and the overview, with the panel's environment, frame
/// and width as ever. The plugin whose view it is gives it (`registrar.detailTakeover`), so the
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
    /// The panel's overview: `content` is handed the panel's editor and its `onExit`, which gives
    /// the keyboard back to the canvas (a list calls it on Escape), and follows the editor by itself.
    ///
    /// `holdsKeyboard`: while it says so, the panel keeps the overview showing whatever is selected,
    /// one shape too (under the header of several, as ever), so the keys walking a list in it go on
    /// walking it rather than its first step taking it away; once it says no, the panel shows what
    /// the selection calls for. Read in the panel's body, so it reads observable state, as a
    /// takeover's `isActive` does. By default, never:
    ///
    ///     registrar.detailOverview(holdsKeyboard: { $0.tableOfContents?.isWalkedByKeys == true }) { editor, onExit in
    ///         TableOfContentsView(editor: editor, onExit: onExit)
    ///     }
    public mutating func detailOverview<Content: View>(
        holdsKeyboard: @escaping @MainActor (CanvasEditor) -> Bool = { _ in false },
        @ViewBuilder _ content: @escaping @MainActor (_ editor: CanvasEditor, _ onExit: @escaping @MainActor () -> Void) -> Content
    ) {
        contribute(DetailOverview(holdsKeyboard: holdsKeyboard, content: { AnyView(content($0, $1)) }), to: DetailOverviews.self)
    }

    /// A takeover of the panel: while `isActive` holds, `content` (handed the panel's editor and its
    /// `onExit`, as an overview is) shows in place of everything else.
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
    /// The overview a plugin gave, if one did.
    var detailOverview: DetailOverview? { contributions(to: DetailOverviews.self).first?.value }

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
