import AppKit
import Canvas
import TestKit

// Keyboard navigation's principle 6, same key, same meaning, as data a test holds every surface to: what each key
// means everywhere (`KeyMeanings.canonical`), and the named exceptions, each with its reason, as the principle's text
// gives them (`KeyMeanings.exceptions`). A surface (`KeySurface`) says which ways its stops run and which exceptions
// it takes, each by name; a walk presses every key from a middle stop and holds what it did to what the key means
// there (`KeyWalk.expectMeanings`). Test data only: the Keyboard Shortcuts window is generated from what is
// registered, the menu bar and the hints, never from this table.

/// What a key means, the table's middle column.
public enum KeyMeaningOfKey: String, Sendable, CaseIterable, CustomStringConvertible {
    case nextStop = "the next stop"
    case previousStop = "the previous stop"
    case nextPart = "into a selected thing's drawn parts, the next of them"
    case previousPart = "into a selected thing's drawn parts, the previous of them"
    case rowAbove = "the row above"
    case rowBelow = "the row below"
    case itemBefore = "the item before"
    case itemAfter = "the item after"
    case activate = "do or open the focused thing"
    case toggle = "toggle or press the focused thing"
    case back = "back out one level"
    case finish = "finish"
    case into = "into a thing's content"
    case out = "out to its container"
    case filter = "filter a focused list"
    case page = "a page: scroll, or a list's highlight a screenful"

    public var description: String { rawValue }
}

/// What a key was seen to do from a stop: to the next stop of the surface or the one before, a level in or out, an
/// act (the board changed, a card or a menu opened, the tool changed), nothing, or somewhere else.
public enum KeyEffect: String, Sendable, CustomStringConvertible {
    case forward, backward, deeper, shallower, acted, none, elsewhere
    public var description: String { rawValue }
}

/// The P6 table: the meanings, and the named exceptions.
public enum KeyMeanings {
    /// A row of the table: its keys as the principle writes them, the chords a walk presses for them (none for
    /// typing), and what they mean everywhere.
    public struct Row: Sendable {
        public let keys: String
        public let chords: [Chord]
        public let meaning: KeyMeaningOfKey
    }

    /// What each key means everywhere: the principle's table, a row per chord.
    public static let canonical: [Row] = [
        Row(keys: "Tab", chords: [.tab], meaning: .nextStop),
        Row(keys: "⇧Tab", chords: [.backTab], meaning: .previousStop),
        Row(keys: "⌥Tab", chords: [.optionTab], meaning: .nextPart),
        Row(keys: "⌥⇧Tab", chords: [.optionBackTab], meaning: .previousPart),
        Row(keys: "↑", chords: [.up], meaning: .rowAbove),
        Row(keys: "↓", chords: [.down], meaning: .rowBelow),
        Row(keys: "←", chords: [.left], meaning: .itemBefore),
        Row(keys: "→", chords: [.right], meaning: .itemAfter),
        Row(keys: "Return", chords: [.return], meaning: .activate),
        Row(keys: "Space", chords: [.space], meaning: .toggle),
        Row(keys: "Escape", chords: [.escape], meaning: .back),
        Row(keys: "⌘↩", chords: [.commandReturn], meaning: .finish),
        Row(keys: "⌘↓", chords: [Chord(Key.down, .command)], meaning: .into),
        Row(keys: "⌘↑", chords: [Chord(Key.up, .command)], meaning: .out),
        Row(keys: "Page Up", chords: [.pageUp], meaning: .page),
        Row(keys: "Page Down", chords: [.pageDown], meaning: .page),
        Row(keys: "typing", chords: [], meaning: .filter),
    ]

    /// What `chord` means everywhere, if the table has it.
    public static func meaning(of chord: Chord) -> KeyMeaningOfKey? { canonical.first { $0.chords.contains(chord) }?.meaning }

    /// An exception the principle names: the keys it is for, where, what they mean there instead, and why.
    public struct Exception: Sendable {
        public let id: String
        public let keys: [Chord]
        public let place: String
        public let means: String
        public let reason: String
    }

    /// The named exceptions, as the principle's text gives them, and no others.
    public static let exceptions: [Exception] = [
        Exception(id: "canvas-tab", keys: [.tab, .backTab], place: "the canvas", means: "the next and previous shape",
                  reason: "shapes are the canvas's stops: from a shape's part, Tab goes on to the next shape, a level out"),
        Exception(id: "completing-list-tab", keys: [.tab, .backTab], place: "a list that completes typed text (@, /, completions, Jump To)",
                  means: "Tab picks the highlighted row, and with none closes the list and moves on; ⇧Tab closes and moves on",
                  reason: "the list completes what is typed, as a shell's and a code editor's do"),
        Exception(id: "connect-picker-tab", keys: [.tab, .backTab], place: "⌘L's picker",
                  means: "Tab picks the highlighted row, and with none moves nothing; ⇧Tab moves the highlight up",
                  reason: "the picker is modal, as the command bar is: its list stays open whatever is pressed, and Escape leaves it"),
        Exception(id: "note-picker-tab", keys: [.tab], place: "a note picker", means: "Tab never picks",
                  reason: "a pick draws an arrow, too much for a key that moves on"),
        Exception(id: "command-bar-tab", keys: [.tab], place: "the command bar", means: "with nothing to complete, Tab moves nothing",
                  reason: "the bar is one line for one command, modal as Jump To's palette, and Escape leaves it"),
        Exception(id: "text-option-tab", keys: [.optionTab, .optionBackTab], place: "text (a box of the panel, a row's value, the JSON editor)",
                  means: "⌥Tab types a tab, or indents in the JSON editor", reason: "Tab there moves on, so ⌥Tab is how a tab is typed"),
        Exception(id: "canvas-arrows", keys: [.up, .down, .left, .right], place: "the canvas",
                  means: "nudge the selection; with nothing selected, pan", reason: "a board is a plane, not a list"),
        Exception(id: "text-return", keys: [.return], place: "text",
                  means: "a new line where the text takes several (a note's words); a one-line value (a row's) and a box row end editing",
                  reason: "a one-line field has no line to add, so Return commits it as a form's field does; Space toggles a box row, as macOS checkboxes do"),
        Exception(id: "line-return", keys: [.return], place: "a row written as a line (a table's column, an enum's value)",
                  means: "commits the row and opens a line below it, above with the caret at the very start of the row's line; on an empty line, ends editing",
                  reason: "a line is a statement, as a shell's: Return says it's done and starts the next, and an empty one says the list is; at the start of a line a text editor's Return pushes it down"),
        Exception(id: "line-list-return", keys: [.return], place: "a line's list (what fits at a row's caret)",
                  means: "never picks a word; does an action row (\"New type Problem\"); Tab picks",
                  reason: "Return after a word must commit the line, so a highlighted word can't be what it does"),
        Exception(id: "line-option-arrows", keys: [Chord(Key.up, .option), Chord(Key.down, .option)],
                  place: "a row written as a line, and rows selected as items on the canvas",
                  means: "move the rows one place up or down; an API's first header goes up past the endpoints under no header, taking those its prefix covers",
                  reason: "a one-line field has no paragraph for ⌥↑ ⌥↓ to move over, and a row no box for them to resize"),
        Exception(id: "marked-end", keys: [.return, .space], place: "an arrow's end its connection marks (a key's crow's foot or bars)",
                  means: "nothing", reason: "the end is drawn as what the connection means, never a stored head, so there is no head to toggle"),
        Exception(id: "outline-arrows", keys: [.left, .right], place: "an outline (the table of contents)",
                  means: "→ opens a row, ← closes it", reason: "as macOS's outlines do"),
        Exception(id: "canvas-space", keys: [.space], place: "the canvas with nothing focused", means: "held: the Hand",
                  reason: "the Hand is held while Space is, as in every canvas app"),
        Exception(id: "board-pages", keys: [.pageUp, .pageDown], place: "a list grouped by board whose rows are a walk's (the issue walk's list)",
                  means: "the first stop of the previous and next board, wrapping",
                  reason: "a walk's list is read by board, and a screenful of it is not a place anyone is going"),
    ]

    public static func exception(_ id: String) -> Exception? { exceptions.first { $0.id == id } }

    /// What a key of `meaning` may do on a surface whose stops run along `axes`: the move it names, or for a key
    /// that acts, its act or nothing (no thing to act on there); never a move a key of another meaning makes.
    public static func allows(_ meaning: KeyMeaningOfKey, axes: KeySurface.Axes) -> Set<KeyEffect> {
        switch meaning {
        case .nextStop: [.forward]
        case .previousStop: [.backward]
        case .nextPart: [.deeper, .forward, .none]
        case .previousPart: [.deeper, .backward, .none]
        case .rowBelow: axes.contains(.vertical) ? [.forward] : [.none]
        case .rowAbove: axes.contains(.vertical) ? [.backward] : [.none]
        case .itemAfter: axes.contains(.horizontal) ? [.forward] : [.none]
        case .itemBefore: axes.contains(.horizontal) ? [.backward] : [.none]
        case .activate: [.acted, .deeper, .none]
        case .toggle: [.acted, .none]
        case .back: [.shallower]
        case .finish: [.shallower, .none]
        case .into: [.deeper, .none]
        case .out: [.shallower, .none]
        case .filter: [.acted, .none]
        // A page moves the view, or a list's highlight, and acts on nothing; where it takes a walk to the board's first stop
        // somewhere else it says so (`board-pages`).
        case .page: axes.contains(.vertical) ? [.none, .forward, .backward] : [.none]
        }
    }
}

/// A surface of the app as P6 sees it: the ways its stops run, and the named exceptions it takes, each as what the
/// key does there instead.
public struct KeySurface: Sendable {
    /// Which ways a surface's stops run: a column (↑ ↓) or a line (← →), either along its Tab order.
    public struct Axes: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let vertical = Axes(rawValue: 1)
        public static let horizontal = Axes(rawValue: 2)
    }

    /// A key that means something else here: what it does, and the named exception that says so, by its id.
    public struct Override: Sendable {
        public let chord: Chord
        public let effects: Set<KeyEffect>
        public let exception: String

        public init(_ chord: Chord, _ effects: Set<KeyEffect>, exception: String) {
            self.chord = chord
            self.effects = effects
            self.exception = exception
        }
    }

    public let name: String
    public let axes: Axes
    /// The surface is one stop of the loop around it (a list of the panel: its rows are ↑ ↓'s, as a table's are), so
    /// Tab and ⇧Tab go on past it, to the loop's next and previous stop, which is Tab's own meaning and no exception.
    public let isOneStopOfLoop: Bool
    public let overrides: [Override]

    public init(_ name: String, axes: Axes = [], isOneStopOfLoop: Bool = false, overrides: [Override] = []) {
        self.name = name
        self.axes = axes
        self.isOneStopOfLoop = isOneStopOfLoop
        self.overrides = overrides
    }

    /// What `chord` may do here: the override's effects, or what its meaning allows. On one stop of a loop, Tab and
    /// ⇧Tab leave it for the loop's next and previous stop: somewhere else, or a level in or out when that is a part
    /// of the shape or the canvas.
    public func allowed(_ chord: Chord) -> Set<KeyEffect> {
        if let override = overrides.first(where: { $0.chord == chord }) { return override.effects }
        if isOneStopOfLoop, chord == .tab || chord == .backTab { return [.elsewhere, .deeper, .shallower] }
        return KeyMeanings.meaning(of: chord).map { KeyMeanings.allows($0, axes: axes) } ?? []
    }

    /// Each override names an exception of the table, with a reason, for its key: one that names none, or a key the
    /// exception isn't for, is a meaning of the surface's own.
    @MainActor public func expectNamedOverrides(file: StaticString = #fileID, line: UInt = #line) {
        for override in overrides {
            guard let exception = KeyMeanings.exception(override.exception) else {
                expect(false, "\(name): \(override.chord) means something else here with no named exception (\"\(override.exception)\")", file: file, line: line)
                continue
            }
            expect(!exception.reason.isEmpty, "\(name): the exception \(exception.id) gives no reason", file: file, line: line)
            expect(exception.keys.contains(override.chord), "\(name): the exception \(exception.id) isn't for \(override.chord)", file: file, line: line)
        }
    }
}

extension KeyWalk {
    /// P6 on `surface`: from `stops[index]`, each key of the table, its effect classified (`KeyEffect`: the next or
    /// previous of `stops`, a level in or out by `depth`, asked before the key and after it, an act, nothing) and held
    /// to what it may do there. `reset`
    /// brings the walk back to the stop after each key (undoing what it did); `acted` says whether something the walk
    /// can't see changed (a list's rows, a card). Every key that means something else is a line ("The table of
    /// contents: → at toc/3 acted; P6: the item after"), failed unless `pending` has it (`expectGaps`, over the
    /// entries that start with the surface's name).
    public func expectMeanings(of surface: KeySurface, stops: [String], at index: Int, depth: @escaping @MainActor (Focus) -> Int,
                               acted: @escaping @MainActor () -> Bool = { false }, reset: @escaping @MainActor () -> Void,
                               file: StaticString = #fileID, line: UInt = #line) {
        surface.expectNamedOverrides(file: file, line: line)
        // Without an editor the board's revision and the tool compare nil to nil, and only `acted` can see an act.
        guard editor != nil else { return expect(false, "\(surface.name): expectMeanings needs the walk's editor", file: file, line: line) }
        var gaps: [String] = []
        let stop = stops[index]
        let next = stops[(index + 1) % stops.count], previous = stops[(index + stops.count - 1) % stops.count]
        for row in KeyMeanings.canonical {
            for chord in row.chords {
                reset()
                let before = focus
                guard before.id == stop else {
                    expect(false, "\(surface.name): the walk isn't at \(stop) before \(chord), but at \(before.id)", file: file, line: line)
                    return
                }
                let revision = editor?.revision, tool = editor?.currentToolID, deep = depth(before)
                let after = press(chord)
                driver.release(chord)
                let effect: KeyEffect
                // On a surface of two stops the next is the previous: the key's own direction says which it went.
                let backwards = [KeyMeaningOfKey.previousStop, .previousPart, .rowAbove, .itemBefore].contains(KeyMeanings.meaning(of: chord))
                if after.id == next, after.id != stop, !(next == previous && backwards) { effect = .forward }
                else if after.id == previous, after.id != stop { effect = .backward }
                else if editor?.revision != revision || editor?.currentToolID != tool || acted() { effect = .acted }
                else if depth(after) > deep { effect = .deeper }
                else if depth(after) < deep { effect = .shallower }
                else if after.id == stop { effect = .none }
                else { effect = .elsewhere }
                let allowed = surface.allowed(chord)
                if !allowed.contains(effect) {
                    let said = KeyMeanings.meaning(of: chord).map(\.description) ?? "no meaning"
                    gaps.append("\(surface.name): \(chord) at \(stop) \(effect)\(after.id == stop ? "" : " (to \(after.id))"); P6: \(said)")
                }
            }
        }
        reset()
        // Only this surface's pending entries are its own.
        let all = pending
        pending = all.filter { $0.hasPrefix("\(surface.name):") }
        expectGaps(gaps, file: file, line: line)
        pending = all
    }
}
