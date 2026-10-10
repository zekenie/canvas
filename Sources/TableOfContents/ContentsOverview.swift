import Canvas
import DetailPanel
import SwiftUI

extension PluginID {
    public static let contentsOverview: PluginID = "contents-overview"
}

/// The table of contents in the detail panel, where the panel has no one shape to show
/// (`DetailOverviews`): with nothing selected, and under the header of several. A plugin value of
/// its own, after `DetailPanelPlugin` and `TableOfContentsPlugin`: a list without the panel leaves
/// it out and keeps the list's state, which the path's crumbs' menus read too.
public struct ContentsOverviewPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .contentsOverview }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.detailOverview { editor, onExit in TableOfContentsView(editor: editor, onExit: onExit) }
    }
}
