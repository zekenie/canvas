import Boards
import Canvas
import TextEditing

/// A candidate and where it is (`MentionState.place(ofShape:)`): the containers it is inside, or the name of its
/// board when it is in none and that isn't the board shown; nil for a shape directly on the board shown. What a
/// list of shapes to pick from shows for each (a reference's, a row's list of notes).
public struct MentionChoice: Hashable, Sendable {
    public let candidate: MentionCandidate
    public let place: MentionPlace?

    public init(candidate: MentionCandidate, place: MentionPlace?) {
        self.candidate = candidate
        self.place = place
    }

    /// The lines a list shows for these: a shape's symbol in its tint, its name with the matched
    /// characters, and where it is at the trailing end ("Alpha › Beta"; an untitled container by its kind, fainter),
    /// or "Kind · Alpha › Beta" when two are called alike (the place's part only when it isn't the board shown). A place
    /// too long for its room is folded (`PlaceFold`, as the pill's line and the table of contents' rows are): the
    /// first name, "…", the nearest, the nearest always whole; the kind first. Said as "Groceries, Note, in Alpha › Beta, 2 of 7".
    @MainActor public static func items(_ choices: [MentionChoice]) -> [CaretListItem] {
        var counts: [String: Int] = [:]
        for choice in choices { counts[choice.candidate.appearance.label.lowercased(), default: 0] += 1 }
        return choices.enumerated().map { position, choice in
            let appearance = choice.candidate.appearance
            let shared = counts[appearance.label.lowercased(), default: 0] > 1
            let place = choice.place
            let detail: (text: String, dimmed: [Range<Int>], matched: [Range<Int>])?
            if shared {
                detail = place?.detail(after: appearance.kindName + " · ") ?? (appearance.kindName, [], [])
            } else {
                detail = place.map { ($0.text, $0.dimmed, $0.matched) }
            }
            return CaretListItem(appearance.label, matched: choice.candidate.matched, symbol: appearance.systemImage, tint: appearance.tint,
                                 detail: detail?.text, detailMatched: detail?.matched ?? [], detailDimmed: detail?.dimmed ?? [], detailTruncatesHead: place != nil,
                                 place: place?.caretPlace(lead: shared ? appearance.kindName + " · " : ""),
                                 spoken: "\(appearance.label), \(appearance.kindName)\(place.map { ", " + $0.spoken } ?? ""), \(position + 1) of \(choices.count)")
        }
    }
}

extension MentionState {
    /// The candidates with where they are (what a candidate made without one is given: `place(ofShape:)`).
    public func choices(_ candidates: [MentionCandidate]) -> [MentionChoice] {
        candidates.map { MentionChoice(candidate: $0, place: $0.place ?? place(ofShape: $0.id)) }
    }

    /// The same, where two called alike on the board shown would otherwise read alike: a shape on the board shown, called as another
    /// is, says the board's name as its place, as the other says its own. A name that is alone has no place, as in `choices(_:)`.
    public func choicesNamingBoardShown(_ candidates: [MentionCandidate]) -> [MentionChoice] {
        let all = choices(candidates)
        var counts: [String: Int] = [:]
        for choice in all { counts[choice.candidate.appearance.label.lowercased(), default: 0] += 1 }
        let board = MentionPlace(board: editor.name(of: editor.board))
        return all.map { choice in
            guard choice.place == nil, counts[choice.candidate.appearance.label.lowercased(), default: 0] > 1 else { return choice }
            return MentionChoice(candidate: choice.candidate, place: board)
        }
    }

    /// The name of the board a shape is on, nil on the board shown: what Boards calls it
    /// (`editor.name(of:root:)`: its owner's title, else its kind's placeholder, "Untitled Subboard",
    /// else its kind's name), the file's name for the root ("Board" when it has none).
    public func boardName(ofShape id: ShapeID) -> String? {
        guard let board = editor.file.board(containing: id), board != editor.board else { return nil }
        return editor.name(of: board)
    }
}
