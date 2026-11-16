import AppKit
import QueryLanguage
import SwiftUI

/// Constraints' words: the steps, the issue's message and its actions, the names of places with no title, and the
/// label of a constraint's walk.
@MainActor
public enum ConstraintsStyle {
    /// The undo steps of the writer's writes.
    public static let addConstraint = "Add Constraint"
    public static let removeConstraint = "Remove Constraint"
    public static let removeConstraints = "Remove Constraints"
    public static let changeConstraint = "Change Constraint"

    /// The actions on a broken constraint's line, and Move Out's step.
    public static let moveOut = "Move Out"
    public static let showConstraint = "Show Constraint"

    /// What a place with no title is called: a container by its kind's label ("This frame"), a board's top level and
    /// the root (with no name from the host) "This board".
    public static let thisBoard = "This board"
    public static func this(_ label: String) -> String { "This " + label.lowercased() }

    /// What a shape that breaks a constraint is told, and what a refused move says: "Backlog accepts only tasks."
    public static func accepts(_ place: String, _ says: String) -> String { "\(place) accepts \(bare(says))." }

    /// What `/constrain` and the panel's add box say of words the list holds already (nothing is asked, nothing written): "Backlog
    /// already accepts only tasks."
    static func alreadyAccepts(_ place: String, _ says: String) -> String { "\(place) already accepts \(bare(says))." }

    /// Words with the full stop they were written with taken off, to go in a sentence.
    private static func bare(_ says: String) -> String {
        var words = says
        while words.hasSuffix(".") { words.removeLast() }
        return words
    }

    /// The first of a place's constraints, as VoiceOver and the panel's rows say several: "only tasks and 2 more".
    static func spoken(_ says: [String]) -> String {
        guard let first = says.first else { return "" }
        return says.count > 1 ? "\(bare(first)) and \(says.count - 1) more" : bare(first)
    }

    /// What VoiceOver hears of a container that accepts only some shapes, after what it is: "accepts only tasks and 2 more".
    static func acceptsSpoken(_ says: [String]) -> String { "accepts " + spoken(says) }

    /// A constraint's walk, as the band names it: "Backlog: only tasks".
    public static func walkLabel(_ place: String, _ says: String) -> String { "\(place): \(says)" }

    /// How far a constraint reaches, as its pop-up and its schema say it.
    public nonisolated static let directlyInside = "Directly inside"
    public nonisolated static let anywhereInside = "Anywhere inside"

    // MARK: The commands

    /// The hints beside `/constrain` and `/unconstrain` in the list.
    /// The words typed after the slash.
    static let constrainCommand = "constrain"
    static let unconstrainCommand = "unconstrain"
    static let constrainArgument = "words"
    static let unconstrainArgument = "constraint"
    /// What the model is told the place is called when several are constrained at once.
    static let eachOfThese = "each of these"
    /// The row that takes every constraint away, and how many it is; a row's lists, for several.
    static let all = "all"
    static func constraintCount(_ count: Int) -> String { count == 1 ? "1 constraint" : "\(count) constraints" }
    static func inLists(_ count: Int, of lists: Int) -> String { "in \(count) of \(lists)" }

    // MARK: A holder that takes none

    /// What is said where a list can't be written (a type whose schema isn't JSON yet): in the panel and by VoiceOver, and in the
    /// bar for `/constrain`. The shape is named by its title, else its kind.
    static func cantAdd(to name: String) -> String { "Can't add a constraint to \(name)." }
    /// For several at once.
    static func cantAdd(toEach count: Int) -> String { "Can't add a constraint to \(count) of the shapes." }
    /// What a refused change that isn't an add says (a remove, a new reach or query).
    static func cantChange(_ name: String) -> String { "Can't change \(name)'s constraints." }

    // MARK: The menus

    /// A container's submenu, a constraint's reach in a menu (title case, as a menu's items are), Remove, Remove All and Show.
    static let constraintsMenu = "Constraints"
    static func menuTitle(of reach: ConstraintReach) -> String {
        switch reach {
        case .children: "Directly Inside"
        case .descendants: "Anywhere Inside"
        }
    }
    static let remove = "Remove"
    static let removeAll = "Remove All Constraints"
    static let showConstraints = "Show Constraints"
    /// A breaker's item: "Move Out of Backlog".
    static func moveOutOf(_ place: String) -> String { "Move Out of \(place)" }
    /// A constraint's words in a menu or a list of choices: cut to a line.
    static func cut(_ says: String) -> String {
        says.count <= menuLength ? says : String(says.prefix(menuLength - 1)) + "…"
    }
    static let menuLength = 60

    // MARK: The funnel chip

    /// The chip's symbol and its name to VoiceOver, with how many shapes break a constraint where there are some.
    public static let funnelSymbol = "line.3.horizontal.decrease"
    public nonisolated static let chipTitle = "Constraints"
    /// The funnel as a part: "Constraints, only tasks", and ", 2 not accepted" when some shapes break one.
    public static func chipSpoken(_ says: [String], notAccepted count: Int) -> String {
        count > 0 ? "\(chipTitle), \(spoken(says)), \(count) not accepted" : "\(chipTitle), \(spoken(says))"
    }
    /// The chip's tooltip: what the place accepts, the words as typed, and how many break it.
    public static func help(_ says: [String], notAccepted count: Int) -> String {
        let accepts = "Accepts: " + says.joined(separator: "; ")
        return count > 0 ? accepts + "\n" + notAccepted(count) : accepts
    }
    public static func notAccepted(_ count: Int) -> String { "\(count) not accepted" }

    // MARK: The board's funnel

    /// The pill's words: what the board accepts, the first constraint's words and "and 2 more" for others: "Accepts only tasks".
    public static func pillWords(_ says: [String]) -> String { "Accepts " + spoken(says) }
    /// The View menu's item and the canvas's context menu's: the pill's click, for the keyboard (it opens the popover and takes the
    /// keyboard into it), and the popover as assistive apps name it.
    public static let showBoardConstraints = "Show Board Constraints"
    public static let popoverLabel = "Board constraints"
    /// Between the pill's symbol and its words, and its words and the count.
    public static let pillSpacing: CGFloat = 4
    /// The room the words are given at least, in view points, before they are left out and the symbol and the count remain.
    public static let pillMinWords: CGFloat = 36
    /// From the pill's right edge to the board's path pill, at least.
    public static let pillClearance: CGFloat = 8
    /// The popover under the pill: how wide, how far its arrow's tip stands below the pill, the arrow's size, how far its contents
    /// stand in, and how near the canvas's bottom edge it may come.
    public static let popoverWidth: CGFloat = 320
    static let popoverGap: CGFloat = 4
    static let arrowSize = CGSize(width: 14, height: 7)
    static let popoverInset: CGFloat = 14
    static let popoverMargin: CGFloat = 12
    /// How near the card's corner the arrow may come.
    static let arrowEdge: CGFloat = 22

    // MARK: The Rules tab

    /// The heads of a container's sections: its own constraints, and the shapes inside that break one.
    static let own = "Own"
    /// The heading of a container's rows when no list from elsewhere is shown above them.
    static let accepts = "Accepts"
    /// "Own" is said against lists from elsewhere; alone, the rows are what the place accepts.
    public static func ownHeading(hasSources: Bool) -> String { hasSources ? own : accepts }
    static let notAcceptedHeading = "Not accepted"
    /// How much of its look a read-only query box keeps in a holder's rows from elsewhere, as their words and reach are dimmer.
    static let dimmedOpacity = 0.6
    /// The empty box last in a list, where a constraint is added, and what VoiceOver calls the boxes of the rows.
    static let addPlaceholder = "add constraint"
    static func rowLabel(_ number: Int) -> String { "Constraint \(number)" }
    /// The query a draft of words came to, before it is written.
    static let draftQueryLabel = "Query for the words"
    /// The row's query box, its reach pop-up and its remove button.
    static func queryLabel(_ says: String) -> String { "Query of \(says)" }
    static func reachLabel(_ says: String) -> String { "Reach of \(says)" }
    static func removeLabel(_ says: String) -> String { "Remove \(says)" }
    /// A constraint a place has from elsewhere, as VoiceOver hears it: "only tasks, directly inside, from Sprint".
    static func inherited(_ says: String, reach: String, from name: String?) -> String {
        [says, reach.lowercased(), name.map { "from \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }
    /// A holder's section heading, over what its places are called ("each sprint": the holder's noun): "Inside each sprint".
    static func inside(_ places: String) -> String { "Inside \(places)" }
    /// Words not interpreted and nobody asking: the row's button.
    static let interpret = "Interpret"
    /// The menu's item for it, and the menu's way to a list's source.
    static let interpretConstraint = "Interpret Constraint"
    static func goTo(_ name: String) -> String { "Go to \(name)" }
    /// A breaker's row at VoiceOver: "Fix the bug, breaks only tasks", and "breaks only work and 2 more" for a shape that breaks
    /// several of the place's.
    /// The words go bare, as every sentence of Constraints' has them, so one written with a full stop reads "breaks only tiles and 1 more".
    public static func breaks(_ name: String, _ says: String, more: Int = 0) -> String { "\(name), breaks \(bare(says))" + (more > 0 ? " and \(more) more" : "") }
    /// A breaker's row: the first constraint it breaks (bare), and how many others as a count of its own, "+2": the view draws the
    /// words cut at the end if they are long, and the count after them, never cut.
    public static func breakDetail(_ says: String, more: Int) -> (words: String, count: String?) { (bare(says), more > 0 ? "+\(more)" : nil) }
    /// What a shape with no title is called in the list of shapes that break a constraint.
    static let untitled = "Untitled"
    static let notAcceptedList = "Not accepted"
    /// A row's box: two lines of the panel's text (a sentence is longer than a line), and the query's box under it.
    static let boxHeight: CGFloat = 40
    /// The pill of a source, and a row's measures.
    static let rowSpacing: CGFloat = 4
    static let pairSpacing: CGFloat = 6
    static let queryGap: CGFloat = 3
    static let removeSymbol = "xmark"
    static let removeTop: CGFloat = 5
    static let fallbackSymbol = "square"
    static let pillPadding = CGSize(width: 6, height: 1)
    static let sectionSpacing: CGFloat = 8
    static let pillSize: CGFloat = 11
    static let captionSize: CGFloat = 10

    /// Why every constraint checks nothing in a list with no queries.
    static var noQueries: QueryError { QueryError(.unsupported, "Nothing in this app answers queries.") }
}
