import Canvas
import Keyboard
import Selection
import SwiftUI

extension CanvasCommand {
    /// View › Next Inspector Tab (⌥⌘]): the panel's next tab for the shape selected, round the ends.
    public static let nextInspectorTab: CanvasCommand = "nextInspectorTab"
    /// View › Previous Inspector Tab (⌥⌘[).
    public static let previousInspectorTab: CanvasCommand = "previousInspectorTab"
}

/// The panel's own contribution: its state, and the panel as the window's inspector (the host's
/// slot for one). Every section in it is some plugin's.
///
/// The inspector has something to show while shapes are selected: with nothing selected the window
/// hides it, whether or not the person has it shown. It's wanted while a takeover or a band is active,
/// whether or not the person has it shown or anything is selected: a takeover is something open in the
/// panel (Find), a band something held over it (the walk's), which would go on with nothing shown to end
/// it by. So the window shows a hidden inspector for it, and hiding the inspector meanwhile escapes the
/// takeover, as Escape in the panel does, and cancels the band, as ⌘. does.
public struct DetailPanelPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .detailPanel }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { DetailPanelState(editor: $0) }
        registrar.hostInspector(width: PaneWidth(min: DetailStyle.minWidth, ideal: DetailStyle.idealWidth, max: DetailStyle.maxWidth),
                                shownWhile: { !$0.selectedShapeIDs.isEmpty },
                                isRequested: { $0.registry.activeDetailTakeover(in: $0) != nil || $0.registry.activeDetailBand(in: $0) != nil },
                                onDismiss: { editor in
                                    // Both found before either runs: ending the takeover may end the band's reason too.
                                    let takeover = editor.registry.activeDetailTakeover(in: editor), band = editor.registry.activeDetailBand(in: editor)
                                    takeover?.onEscape(editor)
                                    band?.onCancel(editor)
                                },
                                keyboardEntry: { $0.detailPanel?.keyboardEntry?() }) { editor, onExit in
            DetailPanelView(editor: editor, onExit: onExit)
        }
        // Tabs by key: a click on a strip is a mouse's, so the keys have commands (View ▸, after Focus
        // Inspector), which the keyboard goes on into the tab they show.
        registrar.command(.nextInspectorTab, title: DetailStyle.nextTab, in: ViewMenu.Panels.self,
                          shortcut: KeyChord("]", [.command, .option]),
                          isEnabled: { $0.editor.detailPanel?.canStepTab == true }) { $0.editor.detailPanel?.stepTab(by: 1) }
        registrar.command(.previousInspectorTab, title: DetailStyle.previousTab, in: ViewMenu.Panels.self,
                          shortcut: KeyChord("[", [.command, .option]),
                          isEnabled: { $0.editor.detailPanel?.canStepTab == true }) { $0.editor.detailPanel?.stepTab(by: -1) }
        // What the panel's text answers to, for the Keyboard Shortcuts window.
        registrar.keyHint(DetailStyle.tabKeys, DetailStyle.tabHint, while: .text)
        registrar.keyHint(DetailStyle.typeTabKeys, DetailStyle.typeTabHint, while: .text)
        registrar.keyHint(DetailStyle.escapeKeys, DetailStyle.escapeHint, while: .text)
        registrar.keyHint(DetailStyle.commitKeys, DetailStyle.commitHint, while: .text)
        registrar.keyHint(DetailStyle.completeKeys, DetailStyle.completeHint, while: .text)
    }
}
