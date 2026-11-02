import AppKit
import Canvas
import DetailPanel
import Palette
import SwiftUI

/// The walk's band over the panel, one row: the scope (a type's chip and "Rule 1", else "All Issues"), then ‹ the place of the
/// stop among the stops › and Done, and a spinner while the first answer is on its way. The place is a button: it opens and
/// closes the walk's list (Go › Issue List, the command: dimmed as it is). The step buttons and Done run the walk's commands (Previous Issue, Next Issue,
/// End Issue Walk), so each has its menu item and key.
/// While the current stop is not open (ignored, or holds) its number is kept and drawn dimmed, as "12 of 62".
struct IssueBand: View {
    let editor: CanvasEditor

    var body: some View {
        if let walk = editor.issueWalk, walk.isRunning {
            VStack(spacing: 0) {
                HStack(spacing: IssueWalkStyle.bandSpacing) {
                    if let label = walk.scope?.label(editor) { ScopeLabel(label: label) }
                    Spacer(minLength: 0)
                    if walk.isGathering { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                    DetailCommandButton(command: .previousIssue, systemImage: IssueWalkStyle.previousSymbol)
                        .labelStyle(.iconOnly)
                    if let number = walk.number {
                        let place = IssueWalkStyle.count(number: number, of: walk.total)
                        // The command's own button: the click, the menu item and the key share one enabled rule.
                        DetailCommandButton(command: .issueList) {
                            Text(place).monospacedDigit().foregroundStyle(walk.currentRow?.isOpen == false ? .secondary : .primary)
                        }
                        .accessibilityLabel(place)
                        // A click or Return: a button answers Space, and Return only as the default (P6).
                        .onKeyPress(.return) {
                            editor.perform(.issueList)
                            return .handled
                        }
                    }
                    DetailCommandButton(command: .nextIssue, systemImage: IssueWalkStyle.nextSymbol)
                        .labelStyle(.iconOnly)
                    DetailCommandButton(command: .endIssueWalk, title: IssueWalkStyle.done)
                }
                .detailTitleRow(else: IssueWalkStyle.bandInset)
                Divider()
            }
            .background(KeyboardWatch(lights: editor.issueLights, keyboard: walk.listKeyboard))
        }
    }
}

/// Tells the walk's light when the window's keyboard moves (into the band's controls, out of them to the panel under it or the
/// canvas): where it is, `DetailPanelState.keyboardPlace`, is read when asked and observed by nothing, and the light shows
/// while it is in the band. The band's own controls cannot say: with Keyboard navigation off they take no focus, and the
/// canvas is not theirs.
private struct KeyboardWatch: NSViewRepresentable {
    let lights: IssueLights?
    let keyboard: IssueListKeyboard

    func makeNSView(context: Context) -> Watcher { Watcher(lights: lights, keyboard: keyboard) }
    func updateNSView(_ view: Watcher, context: Context) { view.lights = lights }

    final class Watcher: NSView {
        weak var lights: IssueLights?
        private let keyboard: IssueListKeyboard
        private var watching: NSKeyValueObservation?

        init(lights: IssueLights?, keyboard: IssueListKeyboard) {
            self.lights = lights
            self.keyboard = keyboard
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        // Stopped before the window goes: an observation of a window that is gone crashes.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            watching?.invalidate()
            watching = nil
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            keyboard.window = window
            guard let window else { return }
            watching = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.lights?.keyboardMayHaveMoved() }
            }
            lights?.keyboardMayHaveMoved()
        }
    }
}

/// The scope's name: its chip, when it has one, then the title; spoken as the label says.
private struct ScopeLabel: View {
    let label: IssueScopeLabel

    var body: some View {
        HStack(spacing: IssueWalkStyle.chipSpacing) {
            if let chip = label.chip {
                Text(chip.name)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: NSColor(chip.swatch.ink)))
                    .padding(.horizontal, IssueWalkStyle.chipPadding.horizontal)
                    .padding(.vertical, IssueWalkStyle.chipPadding.vertical)
                    .background(Capsule().fill(Color(nsColor: NSColor(chip.swatch.wash))))
            }
            Text(label.title)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.spoken ?? label.title)
    }
}
