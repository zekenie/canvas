import AppKit

/// Publishing's words and symbols, in one place.
@MainActor
enum PublicStyle {
    /// The chip's and the row mark's symbol, and the symbol of the "Private" a shape just went to.
    static let symbol = "globe"
    static let publicWord = "Public"
    static let privateWord = "Private"
    static let makePublic = "Make Public"
    static let makePrivate = "Make Private"
    nonisolated static let referencedIn = "Referenced In"
    /// Between "Public" and how many things stand for the shape.
    static let countSeparator = " · "
    /// What a row in Referenced In says when its stand-in's kind describes no symbol: the kind's own,
    /// else this.
    static let fallbackSymbol = "arrow.up.forward"
    /// What the shape standing for another is called when it has no title or kind label.
    static let fallbackName = "Shape"
    /// What a board that isn't the root is called when it has no owner to name it, and the root
    /// (the file's name is the host's, which a concern doesn't know).
    static let boardName = "Board"
    /// How many names Referenced In gives for what's connected through a stand-in, before " +n".
    static let namesShown = 2

    /// "Public", or "Public · 3" once three things stand for the shape.
    static func face(references count: Int) -> String {
        count > 0 ? publicWord + countSeparator + String(count) : publicWord
    }

    /// The tooltip of a row's mark: "Public", or "Public · 3 references".
    static func help(references count: Int) -> String {
        switch count {
        case 0: publicWord
        case 1: publicWord + countSeparator + "1 reference"
        default: publicWord + countSeparator + "\(count) references"
        }
    }
}
