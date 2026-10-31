import Canvas
import DetailPanel
import Keyboard
import SwiftUI

/// The issue walk's views, a plugin of its own after `IssueWalkPlugin` and the detail panel, so a list without the panel leaves
/// them out (the registry refuses a band where the panel isn't installed): the band over the panel while a walk runs, and the
/// light the walk's other stops are lit in while the keyboard is in the band (`IssueLights`). The band's `onCancel` ends the
/// walk: ⌘. in the panel and hiding the inspector do; Escape goes from the band to the canvas, the walk going on.
///
/// And the list (`IssueList`): Go › Issue List (⌃⌘') and a takeover holding the walk's rows by board over the current stop's
/// Issues tab, active while the walk runs with its list open. A list without the panel has no Issue List, so the command is
/// this plugin's; Ignore Issue, placed after it, goes where it would without it when it isn't there. Another takeover listed
/// before the walk's (Find's panel) covers the list: the list is then closed, and Issue List, the key and the band's count are
/// dimmed until it goes.
public struct IssueWalkPanelPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { Self.pluginID }
    static let pluginID: PluginID = "issue-walk-panel"

    public func register(into registrar: inout PluginRegistrar) {
        registrar.detailBand(isActive: { $0.issueWalk?.isRunning ?? false }, onCancel: { $0.issueWalk?.end() }) { editor, _ in
            IssueBand(editor: editor)
        }
        registrar.detailTakeover(isActive: { $0.issueWalk.map { $0.isRunning && $0.isListOpen } ?? false },
                                 onEscape: { $0.issueWalk?.closeListOnEscape() }) { editor, _ in
            IssueList(editor: editor)
        }
        registrar.command(.issueList, title: IssueWalkStyle.issueList, in: IssuesSection.self, placed: .after(.previousIssue),
                          shortcut: KeyChord("'", [.command, .control]), runs: .betweenPresses,
                          isEnabled: { $0.editor.issueWalk?.canToggleList ?? false }) { $0.editor.issueWalk?.toggleList() }
        registrar.service { IssueLights(editor: $0) }
        registrar.outlines { $0.issueLights?.outlines ?? Outlines() }
    }
}
