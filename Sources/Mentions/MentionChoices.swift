import Canvas
import TextEditing
import Titles

/// A candidate and where it is: the name of its board when that isn't the board shown (nil on it).
/// What a list of shapes to pick from shows for each (the `@` picker's rows, a reference's, a
/// row's list of notes).
public struct MentionChoice: Hashable, Sendable {
    public let candidate: MentionCandidate
    public let board: String?

    public init(candidate: MentionCandidate, board: String?) {
        self.candidate = candidate
        self.board = board
    }

    /// The lines a list shows for these: a shape's symbol in its tint, its name with the matched
    /// characters, and the board's name at the trailing end, or "Kind · Board" when two are called
    /// alike (the board's part only when it isn't the board shown). Said as "Groceries, Note, 2 of 7".
    @MainActor public static func items(_ choices: [MentionChoice]) -> [CaretListItem] {
        var counts: [String: Int] = [:]
        for choice in choices { counts[choice.candidate.appearance.label.lowercased(), default: 0] += 1 }
        return choices.enumerated().map { position, choice in
            let appearance = choice.candidate.appearance
            let shared = counts[appearance.label.lowercased(), default: 0] > 1
            let detail = shared ? ([appearance.kindName] + (choice.board.map { [$0] } ?? [])).joined(separator: " · ") : choice.board
            return CaretListItem(appearance.label, matched: choice.candidate.matched, symbol: appearance.systemImage, tint: appearance.tint,
                                 detail: detail, spoken: "\(appearance.label), \(appearance.kindName), \(position + 1) of \(choices.count)")
        }
    }
}

extension MentionState {
    /// The candidates with their boards.
    public func choices(_ candidates: [MentionCandidate]) -> [MentionChoice] {
        candidates.map { MentionChoice(candidate: $0, board: boardName(ofShape: $0.id)) }
    }

    /// The name of the board a shape is on, nil on the board shown: its owner's title, else its
    /// owner's kind's name, else "Board" for the root (whose name is the file's, which the host knows).
    public func boardName(ofShape id: ShapeID) -> String? {
        guard let board = editor.file.board(containing: id), board != editor.board else { return nil }
        guard let owner = editor.owner(of: board) else { return MentionStyle.rootBoardName }
        return registry.title(of: owner) ?? registry.label(of: owner.kind).name
    }
}
