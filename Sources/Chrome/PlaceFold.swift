import CoreGraphics

/// One step of a place, an address: a container a shape is inside, said by its name. A place is its steps,
/// outermost first (the frames and boards the shape is in that the viewer isn't).
public struct PlaceStep: Equatable, Hashable, Sendable {
    public var name: String
    /// Whether going into it opens another board (a subboard, or the board that leads a place): said in the semibold.
    public var opensBoard: Bool
    /// Whether it has no title, `name` being what its kind is called ("Untitled Frame"): said fainter.
    public var isPlaceholder: Bool

    public init(name: String, opensBoard: Bool = false, isPlaceholder: Bool = false) {
        self.name = name
        self.opensBoard = opensBoard
        self.isPlaceholder = isPlaceholder
    }
}

/// One piece of a folded line, in order: a step's text (whole or cut), a separator, or the "…" for the steps left out.
public struct PlacePiece: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The step at `index` of the steps folded.
        case step(index: Int, opensBoard: Bool, isPlaceholder: Bool)
        case separator
        case ellipsis
    }

    public var kind: Kind
    /// What is said: the step's name or the part of it kept, " › ", or "…".
    public var text: String
    /// Whether a step's name was cut at its end.
    public var wasCut: Bool

    public var isStep: Bool { if case .step = kind { true } else { false } }
}

/// What a place says in the room it has: the pieces to draw in order, their width, and whether anything was left
/// out or cut (when it was, the whole place is told on hover, in a panel and to VoiceOver).
public struct PlaceLine: Equatable, Sendable {
    public var pieces: [PlacePiece]
    public var width: CGFloat
    /// Whether any step is left out (a "…" is in the line).
    public var isFolded: Bool
    /// Whether any step's name is cut at its end.
    public var isCut: Bool

    public static let empty = PlaceLine(pieces: [], width: 0, isFolded: false, isCut: false)

    public var isEmpty: Bool { pieces.isEmpty }
    /// Whether the line says less than the whole place.
    public var isShortened: Bool { isFolded || isCut }

    /// The line as plain text, "Shop › … › Disputes".
    public var text: String { pieces.map(\.text).joined() }
}

/// The fold: one function for every place that says an address (the pill's line over its name, the table of
/// contents' row, the lists, the inspector's header). It takes the steps outermost first, the room in points and the
/// width of text in the surface's fonts (a board's name and a frame's may differ: `isBoard`), and answers the line
/// to show, the first of these that fits:
///
/// 1. The whole place.
/// 2. First › … › nearest, putting back as much of the middle as fits: the board the original is on (the innermost
///    step that opens a board, when it's in the middle), then the middle from the near end outward, one at a time,
///    stopping at the first name that isn't a board and doesn't fit. Each run left out is one "…", so two at most.
/// 3. With the middle empty, First › … › m › nearest, the first name cut at its end (never under 34 points) to
///    make room for `m`, the first step 2 would put back.
/// 4. First › … › nearest with the first name (and any middle one) cut at its end, never under 34 points; the
///    nearest stays whole.
/// 5. … › nearest, the nearest cut at its end only if it doesn't fit alone; a name that is a path with no spaces
///    keeps its leaf.
/// 6. Nothing, with under 24 points of room.
///
/// A cut falls at a word when one is within 30% of where it would fall by characters. "…" carries no count.
public enum PlaceFold {
    /// The separator between steps, as it is measured.
    public static let separator = " › "
    public static let ellipsis = "…"
    /// The least a name is cut to, the table of contents' row's floor.
    public static let nameFloor: CGFloat = 34
    /// Under this much room, no line.
    public static let leastRoom: CGFloat = 24

    /// The width of `text` set in the surface's font, a board's name (`isBoard`) in its own.
    public typealias Measure = (_ text: String, _ isBoard: Bool) -> CGFloat

    public static func line(for steps: [PlaceStep], room: CGFloat, measure: Measure) -> PlaceLine {
        withoutActuallyEscaping(measure) { measure in
            var fold = Folding(steps: steps, measure: measure)
            return fold.line(room: room)
        }
    }
}

/// A line being worked out: parts (a step's text, or a "…" for steps left out) between separators.
private struct Part {
    var step: Int?
    var text: String
    var wasCut = false
}

private struct Folding {
    let steps: [PlaceStep]
    let measure: PlaceFold.Measure
    var memo: [String: CGFloat] = [:]

    init(steps: [PlaceStep], measure: @escaping PlaceFold.Measure) {
        self.steps = steps
        self.measure = measure
    }

    mutating func width(_ text: String, board: Bool) -> CGFloat {
        let key = (board ? "b" : "r") + text
        if let known = memo[key] { return known }
        let measured = measure(text, board)
        memo[key] = measured
        return measured
    }

    func isBoard(_ part: Part) -> Bool { part.step.map { steps[$0].opensBoard } ?? false }

    mutating func width(of parts: [Part]) -> CGFloat {
        var total: CGFloat = 0
        for part in parts { total += width(part.text, board: isBoard(part)) }
        return total + width(PlaceFold.separator, board: false) * CGFloat(max(0, parts.count - 1))
    }

    /// The steps `keep` names, in order, one "…" for each run left out.
    func render(_ keep: Set<Int>) -> [Part] {
        var parts: [Part] = []
        var gap = false
        for (index, step) in steps.enumerated() {
            if keep.contains(index) {
                if gap { parts.append(Part(step: nil, text: PlaceFold.ellipsis)) }
                parts.append(Part(step: index, text: step.name))
                gap = false
            } else {
                gap = true
            }
        }
        return parts
    }

    func result(_ parts: [Part], width: CGFloat) -> PlaceLine {
        var pieces: [PlacePiece] = []
        for (position, part) in parts.enumerated() {
            if position > 0 { pieces.append(PlacePiece(kind: .separator, text: PlaceFold.separator, wasCut: false)) }
            if let index = part.step {
                let step = steps[index]
                pieces.append(PlacePiece(kind: .step(index: index, opensBoard: step.opensBoard, isPlaceholder: step.isPlaceholder),
                                         text: part.text, wasCut: part.wasCut))
            } else {
                pieces.append(PlacePiece(kind: .ellipsis, text: part.text, wasCut: false))
            }
        }
        return PlaceLine(pieces: pieces, width: width,
                         isFolded: parts.contains { $0.step == nil } || parts.compactMap(\.step).count < steps.count,
                         isCut: parts.contains(where: \.wasCut))
    }

    mutating func line(room: CGFloat) -> PlaceLine {
        let count = steps.count
        guard count > 0, room >= PlaceFold.leastRoom else { return .empty }
        let whole = render(Set(0..<count))
        let wholeWidth = width(of: whole)
        if wholeWidth <= room { return result(whole, width: wholeWidth) }

        var keep: Set<Int> = [0, count - 1]
        let parts = render(keep)
        if count >= 3 {
            let boards = (1..<(count - 1)).filter { steps[$0].opensBoard }
            let ownBoard = boards.last
            var order: [Int] = []
            if let ownBoard { order.append(ownBoard) }
            order += (1..<(count - 1)).reversed().filter { $0 != ownBoard }
            if width(of: parts) <= room {
                var putBack = false
                for index in order {
                    if width(of: render(keep.union([index]))) <= room {
                        keep.insert(index)
                        putBack = true
                    } else if index != ownBoard {
                        break
                    }
                }
                if putBack {
                    let kept = render(keep)
                    return result(kept, width: width(of: kept))
                }
                // Step 3: the middle stayed empty; cut the first name to bring its first step back.
                if let attempt = withNearestsCompany(index: ownBoard ?? count - 2, room: room) { return attempt }
                return result(parts, width: width(of: parts))
            }
        }

        // Step 4: names cut at their ends, the first (and any middle kept) before the nearest.
        let names = parts.indices.filter { parts[$0].step != nil }
        let near = names[names.count - 1]
        var cut = parts
        for position in names.dropLast() {
            let over = width(of: cut) - room
            if over <= 0 { break }
            let part = parts[position]
            let board = isBoard(part)
            let own = width(part.text, board: board)
            let target = max(min(own, PlaceFold.nameFloor), own - over)
            let text = cutEnd(part.text, room: target, board: board)
            cut[position] = Part(step: part.step, text: text, wasCut: text != part.text)
        }
        let cutWidth = width(of: cut)
        if cutWidth <= room { return result(cut, width: cutWidth) }

        // Step 5: the nearest alone after a "…", whole if it fits, else cut at its end.
        let nearest = parts[near]
        let board = isBoard(nearest)
        if count == 1 {
            let text = cutEnd(nearest.text, room: room, board: board)
            let single = [Part(step: nearest.step, text: text, wasCut: text != nearest.text)]
            return result(single, width: width(of: single))
        }
        let space = room - width(PlaceFold.ellipsis, board: false) - width(PlaceFold.separator, board: false)
        let text = cutEnd(nearest.text, room: space, board: board)
        let only = [Part(step: nil, text: PlaceFold.ellipsis), Part(step: nearest.step, text: text, wasCut: text != nearest.text)]
        return result(only, width: width(of: only))
    }

    /// First › … › step › nearest with the first name cut at its end to make room, if it fits and the first is not
    /// cut under the floor.
    mutating func withNearestsCompany(index: Int, room: CGFloat) -> PlaceLine? {
        let count = steps.count
        var parts = render([0, index, count - 1])
        let first = parts[0]
        let board = isBoard(first)
        let own = width(first.text, board: board)
        let over = width(of: parts) - room
        if over <= 0 { return result(parts, width: width(of: parts)) }
        let target = own - over
        if target < min(own, PlaceFold.nameFloor) { return nil }
        let text = cutEnd(first.text, room: target, board: board)
        parts[0] = Part(step: first.step, text: text, wasCut: text != first.text)
        let total = width(of: parts)
        return total <= room ? result(parts, width: total) : nil
    }

    // MARK: Cutting

    /// `name` cut at its end to fit `room`, "Workflows (loyalty…": at the last word boundary when that keeps at least
    /// seven tenths of what a cut by characters keeps. A name that is a path with no spaces keeps its leaf
    /// ("nexus-messaging…/caller").
    mutating func cutEnd(_ name: String, room: CGFloat, board: Bool, keepsLeaf: Bool = true) -> String {
        if width(name, board: board) <= room { return name }
        let budget = room - width(PlaceFold.ellipsis, board: board)
        let letters = Array(name)
        if keepsLeaf, !name.contains(" "), let slash = letters.lastIndex(of: "/"), slash > 0, slash < letters.count - 1 {
            let leaf = String(letters[slash...])
            let first = String(letters[0..<min(slash, 6)])
            let leafWidth = width(leaf, board: board)
            if leafWidth + width(first, board: board) <= budget {
                let head = cutEnd(String(letters[0..<slash]), room: room - leafWidth, board: board, keepsLeaf: false)
                return head + leaf
            }
        }
        // The longest start that fits: a start's width only grows with its length, so halving finds it in a few measures.
        var kept = 0, high = letters.count - 1
        while kept < high {
            let length = (kept + high + 1) / 2
            if width(trimmedEnd(letters[0..<length]), board: board) <= budget { kept = length } else { high = length - 1 }
        }
        if kept == 0 { return PlaceFold.ellipsis }
        let wordEnds: Set<Character> = [" ", "/", "-", "_", "(", ".", ":"]
        let starts: Set<Character> = [" ", "/", "-", "_", "("]
        let from = max(1, Int(Double(kept) * 0.7))
        if from <= kept {
            for length in stride(from: kept, through: from, by: -1) {
                if wordEnds.contains(letters[length - 1]) || (length < letters.count && starts.contains(letters[length])) {
                    kept = length
                    break
                }
            }
        }
        var head = String(letters[0..<kept])
        while let last = head.last, " /-_(.:".contains(last) { head.removeLast() }
        return head + PlaceFold.ellipsis
    }

    private func trimmedEnd(_ letters: ArraySlice<Character>) -> String {
        var text = String(letters)
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }
}
