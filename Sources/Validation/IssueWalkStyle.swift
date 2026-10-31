import AppKit
import Canvas
import Palette
import SwiftUI

/// The words, numbers and look of the issue walk (`IssueWalk`). Quiet: only the words the design lists, the menus', the
/// band's, the scope of a walk of everything, what a row that is no stop reads, and what VoiceOver hears of a step.
@MainActor
public enum IssueWalkStyle {
    // Go's items.
    static let nextIssue = "Next Issue"
    static let previousIssue = "Previous Issue"
    static let ignoreIssue = "Ignore Issue"
    static let endIssueWalk = "End Issue Walk"
    /// Go's Issue List, and what VoiceOver calls the list.
    static let issueList = "Issue List"

    /// The band's words: a walk of every issue, and the button that ends the walk (the menu's End Issue Walk).
    static let allIssues = "All Issues"
    static let done = "Done"
    /// The band's count, "12 of 63": the place of a stop, and of an issue's line (`IssueWalk.lineAction`).
    static func count(_ place: IssuePlace) -> String { count(number: place.number, of: place.total) }
    static func count(number: Int, of total: Int) -> String { "\(number) of \(total)" }
    /// What a row reads once its issue is gone: set aside by an Ignore, or no longer found (a fix made it hold).
    static let ignored = "ignored"
    static let holds = "holds"

    /// The query that finds the shapes with an issue that shows.
    static let query = ":invalid, :warned"
    /// More shapes than this changed at once (a paste, a bulk create) are found again by the query, not read one by one.
    static let readLimit = 2048

    /// What VoiceOver hears of a step: "Issue 12 of 63, Texas, Roger Williams → Laken Riley Act, In line with the member's
    /// record." The board only when it is not the one said before.
    static func step(number: Int, of total: Int, board: String?, name: String, says words: String) -> String {
        let parts = ["Issue \(number) of \(total)"] + (board.map { [$0] } ?? []) + [name, words]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// What it hears of an Ignore: how many stops are left.
    static func ignored(_ left: Int) -> String { "Ignored, \(left)" }

    // MARK: The band

    /// The symbols of the band's step buttons.
    static let previousSymbol = "chevron.left"
    static let nextSymbol = "chevron.right"
    /// The band's inset from the panel's edges, and the space between its parts.
    static let bandInset = EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
    static let bandSpacing: CGFloat = 8
    /// A type's chip beside "Rule 1", as the Rules tab draws one (`RuleLine`): the title in the color's ink on a wash of it.
    static let chipSpacing: CGFloat = 6
    static let chipPadding = (horizontal: CGFloat(5), vertical: CGFloat(1))

    // MARK: The list

    /// The list is at most this share of the panel's height; the current stop's Issues tab has the rest.
    public static let listShare: CGFloat = 0.5
    /// The list takes the keyboard as it opens, tried again every `enterRetry`, at most `enterRetries` times, while its table
    /// is not in the window yet (the panel draws it a turn or two on).
    static let enterRetries = 12
    static let enterRetry: Duration = .milliseconds(20)
    /// A row's symbol when its kind has none.
    static let fallbackSymbol = "square"
    /// What VoiceOver hears of a row besides its name: the board, then its place among the stops, or why it is none.
    static func spoken(board: String, place: IssuePlace?, state: IssueRowState) -> String {
        let last: String
        switch state {
        case .open: last = place.map { count($0) } ?? ""
        case .ignored: last = ignored
        case .holds: last = holds
        }
        return [board, last].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: The light

    /// What the walk's other stops on the board shown are lit in while the keyboard is in the band (or its list), and what a
    /// rule's count or line of Shown lights in (LanguageRules'): one light for both, cyan, clear of Validation's orange and
    /// red and the accent, and at least 3:1 against both canvases (4.6 and 9.9).
    public static let light = NSColor(light: RGB(hex: 0x0B7BB5), dark: RGB(hex: 0x64D2FF))
}
