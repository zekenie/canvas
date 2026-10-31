import Canvas
import DetailPanel
import Observation

/// The walk's light: while the keyboard is in the band over the panel (or in the list the band's count opens), the walk's other
/// stops on the board shown are outlined in `IssueWalkStyle.light`, the core's tinted outlines (`registrar.outlines`), so a
/// person stepping through stops sees where the rest are. The current stop is the selection and is not lit, nor is a row that is
/// no stop (ignored, or holds), nor a stop on another board (a board shown is lit for the stops on it alone: a walk's list is
/// where the others are).
///
/// Where the keyboard is (`DetailPanelState.keyboardPlace`) is read when asked and observed by nothing, so the light asks when it
/// places: as the band's controls gain or lose the keyboard (the band tells it, `keyboardMayHaveMoved()`), as the walk moves or
/// its rows or its list is shown or goes (observed, looked at a turn later), and as the board shown changes. One `Outlines` is kept and the
/// canvas asked to draw only when it changed.
///
/// One light for the walk and the rules (LanguageRules' `RuleLights`): they never show at once, and the rules' yields, since it
/// is lit by a pointer passing over a count and this by the keyboard being in the band (LanguageRules reads `isLit`).
@MainActor
public final class IssueLights {
    private unowned let editor: CanvasEditor
    /// What the canvas outlines for the walk now.
    private(set) var outlines = Outlines()
    private var turn: ScheduledTask?
    /// Whether a registration of `watch()` is pending: Observation tells once, so another is made only after it has told.
    private var isWatching = false

    init(editor: CanvasEditor) {
        self.editor = editor
        watch()
    }

    /// Whether any stop is lit now.
    public var isLit: Bool { !outlines.tinted.isEmpty }

    /// The band's controls gained or lost the keyboard, or it moved to or from the canvas: placed now, and once more a turn
    /// later, when SwiftUI's focus and AppKit's first responder have settled in step.
    func keyboardMayHaveMoved() {
        place()
        again()
    }

    /// Reads what the walk's light depends on, so the next change of any of it is told (Observation tells once).
    private func watch() {
        guard !isWatching, let walk = editor.issueWalk else { return }
        isWatching = true
        withObservationTracking {
            _ = walk.isRunning
            _ = walk.rows
            _ = walk.currentRow?.key
            _ = walk.isListShown
        } onChange: { [weak self] in
            // Told as it's about to change (in its `willSet`): looked at a turn later, when it has.
            MainActor.assumeIsolated {
                self?.isWatching = false
                self?.again()
            }
        }
    }

    private func again() {
        guard turn == nil else { return }
        turn = editor.scheduler.schedule(after: .zero) { [weak self] in
            guard let self else { return }
            turn = nil
            watch()
            place()
        }
    }

    /// Whether the keyboard is where the light shows: in the band, or in a takeover while the walk's own list is what the panel shows.
    private func keyboardIsInWalk(_ walk: IssueWalk) -> Bool {
        switch editor.detailPanel?.keyboardPlace {
        case .band?: true
        case .takeover?: walk.isListShown
        default: false
        }
    }

    /// The stops lit: open ones on the board shown but the current stop's shape, each shape once.
    private func lit(for walk: IssueWalk) -> [ShapeID] {
        let board = editor.board, current = walk.currentRow?.shape
        var seen: Set<ShapeID> = []
        var shapes: [ShapeID] = []
        for row in walk.rows where row.isOpen && row.board == board && row.shape != current && seen.insert(row.shape).inserted {
            shapes.append(row.shape)
        }
        return shapes
    }

    func place() {
        var next = Outlines()
        if let walk = editor.issueWalk, walk.isRunning, keyboardIsInWalk(walk) {
            let shapes = lit(for: walk)
            if !shapes.isEmpty { next = Outlines(tinted: [TintedOutlines(color: IssueWalkStyle.light, shapes: shapes)]) }
        }
        guard next != outlines else { return }
        outlines = next
        editor.setNeedsDisplay()
    }
}

extension IssueLights: EditorService {
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        if isLit || editor.issueWalk?.isRunning == true { place() }
    }
}

extension CanvasEditor {
    /// The walk's light; nil without IssueWalkPanelPlugin.
    public var issueLights: IssueLights? { service(IssueLights.self) }
}
