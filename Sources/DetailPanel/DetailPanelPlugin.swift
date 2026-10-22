import Canvas
import Keyboard
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
/// The inspector is wanted while a takeover is active, whether or not the person has it shown: a
/// takeover is something open in the panel (Find), which would go on with nothing shown to end it
/// by. So the window shows a hidden inspector for it, and hiding the inspector meanwhile escapes the
/// takeover, as Escape in the panel does.
public struct DetailPanelPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .detailPanel }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { DetailPanelState(editor: $0) }
        registrar.hostInspector(isRequested: { $0.registry.activeDetailTakeover(in: $0) != nil },
                                onDismiss: { $0.registry.activeDetailTakeover(in: $0)?.onEscape($0) },
                                keyboardEntry: { $0.detailPanel?.keyboardEntry?() }) { editor, onExit in
            DetailPanelView(editor: editor, onExit: onExit)
        }
        // Tabs by key: a click on a strip is a mouse's, so the keys have commands (View ▸), which the
        // keyboard goes on into the tab they show.
        registrar.command(.nextInspectorTab, title: DetailStyle.nextTab, menu: "View", order: DetailStyle.nextTabOrder,
                          shortcut: KeyChord("]", [.command, .option]),
                          isEnabled: { $0.editor.detailPanel?.canStepTab == true }) { $0.editor.detailPanel?.stepTab(by: 1) }
        registrar.command(.previousInspectorTab, title: DetailStyle.previousTab, menu: "View", order: DetailStyle.nextTabOrder + 1,
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
