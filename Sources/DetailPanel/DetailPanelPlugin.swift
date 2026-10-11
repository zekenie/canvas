import Canvas
import HostSlots
import SwiftUI

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
                                onDismiss: { $0.registry.activeDetailTakeover(in: $0)?.onEscape($0) }) { editor, onExit in
            DetailPanelView(editor: editor, onExit: onExit)
        }
    }
}
