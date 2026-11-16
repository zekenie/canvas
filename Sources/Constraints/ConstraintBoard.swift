import Adornments
import AppKit
import Boards
import Canvas
import Chrome
import DetailPanel
import Observation
import SwiftUI
import Validation

// What the board shown accepts, on the board: a pill at the canvas's top leading corner, on the row of Boards' path (its middle on
// the path's), once the board has constraints of its own: the root's, or a subboard's seen from inside (its own and the lists it has
// from elsewhere). A click opens a popover under it with the Rules tab's own rows (`ConstraintRows`, `SourceRows`,
// `NotAcceptedView`, over the board's place), so the lists are edited where they are read. The host places it over the canvas
// (`registrar.hostOverlay`), as it does the path and Jump To's palette.

/// Whether the board shown has constraints of its own, which the pill says, and whether its popover is open. `editor.constraintBoard`.
@MainActor
@Observable
public final class ConstraintBoard {
    @ObservationIgnored private weak var editor: CanvasEditor?
    /// The board shown, kept so the pill follows another board being shown.
    public private(set) var board: BoardID
    /// Whether the popover shows.
    public private(set) var isOpen = false
    /// Bumped each time the popover is asked for: the keyboard goes to its first control.
    public private(set) var focusRequest = 0

    init(editor: CanvasEditor) {
        self.editor = editor
        board = editor.board
    }

    /// The place the pill is about: the root, on the root, and a subboard's board's owner, inside it; nil while it has no constraint
    /// (none of its own and none from elsewhere), or the owner holds none. Observed by the board shown and by the place.
    public var place: ConstraintTarget? {
        guard let index = editor?.constraintIndex else { return nil }
        let place = board.owner.map(ConstraintTarget.shape) ?? .root
        return index.constraints(of: place).isEmpty ? nil : place
    }

    /// What the pill says now: nil while it shows none. Observed by the board shown and by its place (its constraints, and the shapes
    /// that break one).
    public var pill: ConstraintPill? {
        guard let index = editor?.constraintIndex, let place else { return nil }
        let says = index.acceptedWords(of: place)
        let broken = index.breakers(of: place).count
        return ConstraintPill(place: place, words: ConstraintsStyle.pillWords(says), count: broken > 0 ? broken : nil,
                              spoken: ConstraintsStyle.chipSpoken(says, notAccepted: broken), help: index.funnelHelp(of: place) ?? "")
    }

    /// Opens the popover, the keyboard in it. False while there is no pill.
    @discardableResult
    public func open() -> Bool {
        guard place != nil, let editor else { return false }
        isOpen = true
        focusRequest += 1
        // It has the canvas: a palette that was open is closed, as the popover is when one opens over it.
        editor.presentModalOverlay(ConstraintFacesPlugin.id) { [weak self] in self?.close() }
        return true
    }

    /// Closes it. The keyboard is the caller's to give back.
    public func close() {
        if isOpen { isOpen = false }
        editor?.dismissModalOverlay(ConstraintFacesPlugin.id)
    }

    /// The pill's click: open, or closed while it is.
    public func toggle() {
        if isOpen { close() } else { open() }
    }
}

/// What the board's pill says: the words ("Accepts only tasks"), how many shapes break a constraint (red, with the count, when
/// some do), what VoiceOver hears of it as the button it is (as the funnel chip of a frame is named), and its tooltip.
public struct ConstraintPill: Equatable, Sendable {
    public let place: ConstraintTarget
    public let words: String
    public let count: Int?
    public let spoken: String
    public let help: String
}

extension ConstraintBoard: EditorService {
    /// Another board shown: the pill is about its place, and the popover of the one before closes.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        board = editor.board
        close()
    }
}

extension CanvasEditor {
    /// What the board shown accepts, as the board says it: nil without `ConstraintFacesPlugin`.
    public var constraintBoard: ConstraintBoard? { service(ConstraintBoard.self) }
}

// MARK: The overlay

/// The pill, and under it the popover while it's open, over the whole canvas: nothing while the board has no constraint.
struct BoardFunnel: View {
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void

    var body: some View {
        // Another overlay with the canvas (Jump To's palette, whose field is where the pill would be in a narrow canvas) has it to itself,
        // and so does a card that hangs from no shape (the command bar opened with nothing selected, on the row the pill is on).
        if let board = editor.constraintBoard, let index = editor.constraintIndex, let boxes = editor.constraintBoxes, let pill = board.pill,
           editor.modalOverlay == nil || editor.modalOverlay == ConstraintFacesPlugin.id,
           !editor.showsBoardCard {
            FunnelLayer(editor: editor, board: board, index: index, boxes: boxes, pill: pill, onExit: onExit)
        }
    }
}

/// How the pill is drawn in the room it has.
public enum FunnelFit: Equatable, Sendable {
    /// The symbol, the words and the count.
    case full
    /// The words cut at the end to this wide.
    case words(CGFloat)
    /// The symbol and the count: no room for words.
    case symbolOnly

    /// The pill's width in `available` points (the room from its leading edge to what it keeps clear of), for these words and this
    /// count (the shapes that break one, when some do). The forms are measured as SwiftUI lays them out (`FunnelPillLabel`), so the
    /// width said is the width drawn; the cut form is the words cut to the room (`cut`), as wide as it lays out and never past the room. `symbolOnly`'s width can still be more than
    /// `available`: the caller then puts the pill somewhere with more room.
    @MainActor
    public static func of(words: String, count: Int?, in available: CGFloat) -> (fit: FunnelFit, width: CGFloat) {
        // Whole points: a view is laid out on the pixels, so a width with a fraction is drawn a little wider than it was said to be.
        let available = floor(available)
        let full = measured(words: words, count: count, fit: .full)
        if full <= available { return (.full, full) }
        let symbols = measured(words: words, count: count, fit: .symbolOnly)
        let room = available - symbols - ConstraintsStyle.pillSpacing
        if room >= ConstraintsStyle.pillMinWords {
            // As wide as the cut text is laid out (a hair under the room at most, never over): the count follows the words.
            var room = room
            while true {
                let width = measured(words: words, count: count, fit: .words(room))
                if width <= available || room <= ConstraintsStyle.pillMinWords { return (.words(room), min(width, available)) }
                room -= 1
            }
        }
        return (.symbolOnly, symbols)
    }

    /// How the pill is drawn in a canvas `canvasWidth` wide whose path's pill, in the middle of its top, is `pathWidth` wide (0 while
    /// none shows): on the path's row, 12 in from the leading edge, in the room to the path's pill less `pillClearance`; and, when not
    /// even the symbol and the count fit there (long names in a narrow canvas), `lowered`: on a row of its own under the path, at
    /// the same margin, the canvas's width to itself, never over the path.
    @MainActor
    public static func placed(words: String, count: Int?, canvasWidth: CGFloat, pathWidth: CGFloat) -> (fit: FunnelFit, width: CGFloat, lowered: Bool) {
        let margin = ChromeStyle.floatMargin
        let reach = pathWidth > 0 ? (canvasWidth - pathWidth) / 2 - ConstraintsStyle.pillClearance : canvasWidth - margin
        let beside = max(reach - margin, 0)
        let fitted = of(words: words, count: count, in: beside)
        guard pathWidth > 0, fitted.width > beside else { return (fitted.fit, fitted.width, false) }
        let below = of(words: words, count: count, in: max(canvasWidth - 2 * margin, 0))
        return (below.fit, below.width, true)
    }

    /// The words cut at the end, with an ellipsis, to the most that is `room` wide, as the pill draws them. The most characters
    /// kept that fit is found by halving (the width only grows with each character kept), so a long text costs a few measures, not
    /// one for every character; and what was cut to a room is kept (`Cache`), since a live resize asks the same rooms again.
    @MainActor
    public static func cut(_ words: String, to room: CGFloat) -> String {
        let key = Cache.Key(words: words, room: room)
        if let kept = cache.cuts[key] { return kept }
        let font = ChromeStyle.floatPillFont
        func wide(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let result: String
        if wide(words) <= room {
            result = words
        } else {
            let characters = Array(words)
            var low = 0, high = characters.count
            while low < high {
                let middle = (low + high + 1) / 2
                if wide(String(characters[..<middle]) + "\u{2026}") <= room { low = middle } else { high = middle - 1 }
            }
            result = String(characters[..<low]) + "\u{2026}"
        }
        cache.putCut(result, for: key)
        return result
    }

    /// What was measured and cut, kept as the board's canvas is resized (the pill is laid out on every width of it). The forms that
    /// do not depend on the room (the full one and the symbol's) are kept apart from the cut ones, which a sweep through many widths
    /// fills: past its cap the oldest cut ones go, never the others.
    @MainActor private final class Cache {
        struct Key: Hashable { let words: String; let room: CGFloat }
        var fixed: [String: CGFloat] = [:]
        var cutWidths: [String: CGFloat] = [:]
        var cuts: [Key: String] = [:]
        private var cutOrder: [String] = []
        private var cutKeys: [Key] = []
        static let cap = 256

        func putFixed(_ width: CGFloat, for key: String) {
            if fixed.count > Self.cap { fixed.removeAll() }
            fixed[key] = width
        }

        func putWidth(_ width: CGFloat, for key: String) {
            if cutOrder.count >= Self.cap {
                for old in cutOrder.prefix(Self.cap / 2) { cutWidths[old] = nil }
                cutOrder.removeFirst(Self.cap / 2)
            }
            cutWidths[key] = width
            cutOrder.append(key)
        }

        func putCut(_ text: String, for key: Key) {
            if cutKeys.count >= Self.cap {
                for old in cutKeys.prefix(Self.cap / 2) { cuts[old] = nil }
                cutKeys.removeFirst(Self.cap / 2)
            }
            cuts[key] = text
            cutKeys.append(key)
        }
    }

    @MainActor private static let cache = Cache()

    @MainActor
    private static func measured(words: String, count: Int?, fit: FunnelFit) -> CGFloat {
        let key = "\(fit)\u{0}\(count.map(String.init) ?? "")\u{0}\(words)"
        if case .words = fit {
            if let width = cache.cutWidths[key] { return width }
            let width = ceil(NSHostingView(rootView: FunnelPillLabel(words: words, count: count, fit: fit)).fittingSize.width)
            cache.putWidth(width, for: key)
            return width
        }
        if let width = cache.fixed[key] { return width }
        let width = ceil(NSHostingView(rootView: FunnelPillLabel(words: words, count: count, fit: fit)).fittingSize.width)
        cache.putFixed(width, for: key)
        return width
    }
}

private struct FunnelLayer: View {
    let editor: CanvasEditor
    let board: ConstraintBoard
    let index: ConstraintIndex
    let boxes: ConstraintBoxes
    let pill: ConstraintPill
    let onExit: @MainActor () -> Void

    var body: some View {
        let place = pill.place
        let crumbs = editor.boardCrumbs
        let pathWidth = (crumbs?.crumbs.isEmpty ?? true) ? 0 : (crumbs?.pillWidth ?? 0)
        GeometryReader { canvas in
            let spot = FunnelFit.placed(words: pill.words, count: pill.count, canvasWidth: canvas.size.width, pathWidth: pathWidth)
            let fitted = (fit: spot.fit, width: spot.width)
            let top = spot.lowered ? max(BoardPath.coveredHeight(on: board.board), BoardPath.rowMidline + ChromeStyle.floatPillHeight / 2)
                : BoardPath.rowMidline - ChromeStyle.floatPillHeight / 2
            let popoverTop = top + ChromeStyle.floatPillHeight + ConstraintsStyle.popoverGap
            ZStack(alignment: .topLeading) {
                if board.isOpen {
                    // The scrim: a click anywhere else closes the popover, and isn't the canvas's.
                    Button {
                        board.close()
                        onExit()
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .accessibilityHidden(true)
                }
                FunnelPill(pill: pill, fit: fitted.fit, width: fitted.width) { board.toggle() }
                .padding(.leading, ChromeStyle.floatMargin)
                .padding(.top, top)
                if board.isOpen {
                    FunnelPopover(editor: editor, board: board, index: index, boxes: boxes, place: place, onExit: onExit,
                                  arrowX: fitted.width / 2,
                                  maxHeight: max(canvas.size.height - popoverTop - ConstraintsStyle.popoverMargin, 0))
                        .padding(.leading, ChromeStyle.floatMargin)
                        .padding(.top, popoverTop)
                }
            }
            .frame(width: canvas.size.width, height: canvas.size.height, alignment: .topLeading)
        }
        // The window closing, or the pill going (its last constraint taken away, an undo), closes the popover: it opens by the pill.
        .onDisappear { board.close() }
    }
}

// MARK: The pill

/// What is in the pill, in the room it has: the funnel, the words (all, or cut at the end to `room`, or left out) and the count,
/// in the zoom pill's type and padding. What `FunnelFit` measures and `FunnelPill` draws.
private struct FunnelPillLabel: View {
    let words: String
    let count: Int?
    let fit: FunnelFit
    /// How wide it is drawn: the width `FunnelFit` said, whole points, so what was kept clear is what is covered. Natural if nil.
    var width: CGFloat?

    var body: some View {
        HStack(spacing: ConstraintsStyle.pillSpacing) {
            Image(systemName: ConstraintsStyle.funnelSymbol)
            switch fit {
            case .full: Text(words).lineLimit(1).fixedSize()
            // Cut here, to the room, so the text is as wide as what shows and the count follows it.
            case .words(let room): Text(FunnelFit.cut(words, to: room)).lineLimit(1).fixedSize()
            case .symbolOnly: EmptyView()
            }
            if let count { Text("\(count)").monospacedDigit() }
        }
        .font(Font(ChromeStyle.floatPillFont))
        .padding(.horizontal, ChromeStyle.floatPillPadding)
        .frame(width: width, height: ChromeStyle.floatPillHeight)
    }
}

/// The funnel in the look of the zoom's pill (`floatingSurface`, its height and type from Chrome), quiet while every shape inside
/// fits, and in the funnel chip's red (Validation's error color, the light tint) with how many break one when some do.
private struct FunnelPill: View {
    let pill: ConstraintPill
    let fit: FunnelFit
    let width: CGFloat
    let action: @MainActor () -> Void

    var body: some View {
        let tint = AdornmentTint(Severity.error.color, style: .light)
        let isRed = pill.count != nil
        Button(action: action) {
            FunnelPillLabel(words: pill.words, count: pill.count, fit: fit, width: width)
            .foregroundStyle(isRed ? Color(nsColor: tint.ink) : Color(nsColor: .secondaryLabelColor))
            .floatingSurface(in: Capsule())
            .overlay {
                if isRed {
                    Capsule().fill(Color(nsColor: tint.lightFill))
                        .overlay(Capsule().strokeBorder(Color(nsColor: tint.lightLine), lineWidth: ChromeStyle.hairlineWidth))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .help(pill.help)
        .accessibilityLabel(pill.spoken)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: The popover

/// The popover: a card of the chrome's surface under the pill, its arrow at the pill, holding the board's rows; the panel's own
/// views in the panel's way (`DetailHosted`): Tab walks them, Escape lets go of words typed and then closes it, the keyboard going
/// back to the canvas.
private struct FunnelPopover: View {
    let editor: CanvasEditor
    let board: ConstraintBoard
    let index: ConstraintIndex
    let boxes: ConstraintBoxes
    let place: ConstraintTarget
    let onExit: @MainActor () -> Void
    /// Where the arrow's tip is, from the card's leading edge.
    let arrowX: CGFloat
    /// How tall the card may be before its rows scroll.
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let arrow = ConstraintsStyle.arrowSize
        let edge = ConstraintsStyle.arrowEdge
        let shape = ArrowedCard(arrowX: min(max(arrowX, edge), ConstraintsStyle.popoverWidth - edge))
        let room = max(maxHeight - arrow.height, 0)
        DetailHosted(editor: editor, focus: board.focusRequest, close: { [board, onExit] in
            board.close()
            onExit()
        }, reclaim: onExit) {
            ScrollView {
                BoardConstraintsContent(editor: editor, index: index, boxes: boxes, place: place) { [board, onExit, boxes] ids in
                    board.close()
                    onExit()
                    boxes.go(to: ids)
                }
                    .padding(ConstraintsStyle.popoverInset)
                    .frame(width: ConstraintsStyle.popoverWidth, alignment: .leading)
                    .background { GeometryReader { Color.clear.preference(key: ContentHeight.self, value: $0.size.height) } }
            }
            .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
            .frame(width: ConstraintsStyle.popoverWidth, height: contentHeight > 0 ? min(contentHeight, room) : room)
        }
        .padding(.top, arrow.height)
        .floatingSurface(in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ConstraintsStyle.popoverLabel)
    }
}

/// How tall the popover's rows are.
private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// What the popover holds: the lists the board has from elsewhere (each under its source's pill, read-only), what it accepts (its
/// own rows and the box that adds one), then Not accepted while some shape breaks one: the Rules tab's, for a place. A board that
/// can't change (a locked subboard's) has its rows read-only, as the tab does.
struct BoardConstraintsContent: View {
    let editor: CanvasEditor
    let index: ConstraintIndex
    let boxes: ConstraintBoxes
    let place: ConstraintTarget
    /// Goes to shapes the popover lists (a breaker, a list's source): the popover is the board's, over the shapes, so it gives way
    /// first and the canvas has the keyboard, as Jump To's pick leaves the palette.
    let go: @MainActor ([ShapeID]) -> Void

    var body: some View {
        let sources = index.sources(of: place)
        let own = editor.constraintWriter?.constraints(of: place) ?? []
        VStack(alignment: .leading, spacing: ConstraintsStyle.sectionSpacing) {
            VStack(alignment: .leading, spacing: ConstraintsStyle.sectionSpacing) {
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                    SourceRows(source: source, boxes: boxes, dimmed: false, onGo: go)
                }
                DetailSectionTitle(ConstraintsStyle.ownHeading(hasSources: !sources.isEmpty))
                ConstraintRows(place: place, constraints: own, index: index, boxes: boxes)
            }
            // The board shown can't change when its owner, or a board above, can't: what the editor observes, so a lock or an unlock
            // while the popover is open dims or undims its rows.
            .disabled(editor.isBoardReadOnly)
            if !index.breakers(of: place).isEmpty {
                Divider()
                NotAcceptedView(place: place, index: index, boxes: boxes, onGo: go)
            }
        }
    }
}

/// A card with an arrow on its top edge: a rounded rectangle `ChromeStyle.floatCorner` round, under an arrow as high as
/// `ConstraintsStyle.arrowSize` whose tip is `arrowX` from the leading edge. The shape's rect includes the arrow's room.
private struct ArrowedCard: InsettableShape {
    let arrowX: CGFloat
    var inset: CGFloat = 0
    /// The measures, read where the shape is made (they are the main actor's).
    let arrow: CGSize
    let radius: CGFloat

    @MainActor
    init(arrowX: CGFloat) {
        self.arrowX = arrowX
        arrow = ConstraintsStyle.arrowSize
        radius = ChromeStyle.floatCorner
    }

    func inset(by amount: CGFloat) -> ArrowedCard {
        var inset = self
        inset.inset += amount
        return inset
    }

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + arrow.height, width: rect.width, height: rect.height - arrow.height).insetBy(dx: inset, dy: inset)
        let tipX = rect.minX + arrowX, tipY = rect.minY + inset
        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: tipX - arrow.width / 2, y: body.minY))
        path.addLine(to: CGPoint(x: tipX, y: tipY))
        path.addLine(to: CGPoint(x: tipX + arrow.width / 2, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - radius, y: body.maxY), radius: radius)
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - radius), radius: radius)
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + radius, y: body.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}
