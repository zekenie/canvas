import Canvas
import Keyboard

/// The pill's menu, for the keys and the menu bar (keyboard navigation's principles 1 and 10): Go to
/// Mention (⌥⌘↩) and Show What Mentions in Go, Remove Mention in Edit. Each acts on the pill that is
/// exactly the selection of the text with the keyboard, else the one the caret touches, a note's
/// editor or a panel's box (`MentionState.enter`), through the state the pill's right-click menu
/// goes through: following is scheduled on the next turn, as a double-click's is, since going ends
/// the editing the key came from. None waits for editing to end (`.whenIdle` would hand its key
/// to the text, and they act on text), so each carries ⌘ where it has a key, and with no pill there
/// their items are dimmed and the key goes on. ⌘↓ is the text's move to the end, so not Open
/// Selection's key.
@MainActor
func registerMentionCommands(into registrar: inout PluginRegistrar) {
    registrar.command(.goToMention, title: MentionStyle.goToMention, menu: "Go", order: 30,
                      shortcut: KeyChord(KeyChord.return.key, [.command, .option]), runs: .betweenPresses,
                      isEnabled: { $0.editor.mentions?.canFollowPillOnCaret == true }) { $0.editor.mentions?.followPillOnCaret() }
    registrar.command(.showWhatMentionsOfPill, title: MentionStyle.showWhatMentions, menu: "Go", order: 40, runs: .betweenPresses,
                      isEnabled: { $0.editor.mentions?.canShowWhatMentionsOnCaret == true }) { $0.editor.mentions?.showWhatMentionsOnCaret() }
    registrar.command(.removeMention, title: MentionStyle.removeMention, menu: "Edit", order: 180, runs: .betweenPresses,
                      isEnabled: { $0.editor.mentions?.canRemovePillOnCaret == true }) { $0.editor.mentions?.removePillOnCaret() }
}
