import Adornments
import Canvas
import CoreGraphics
import DetailPanel
import Selection
import TableOfContents
import Topology

/// Per editor: which shapes are public, kept as commits change shapes, what stands for each (read
/// from Topology, which follows every change to the edges, a commit's or a provide's), and the chips
/// showing "Private" for a moment after a shape went private (a `ChipFade`; the shake a refused
/// try gives is Selection's `RefusalShake`).
///
/// `admitting` is what a query engine, or anything that works off the main actor, asks of a shape
/// to know whether it may be stood for: built once, when the editor is, from the kinds that are
/// always public and the kinds that stand in (which are never stood for, as Topology says), and the
/// property's key.
@MainActor
public final class PublishingState {
    unowned let editor: CanvasEditor
    private let topology: TopologyIndex?
    /// The public shapes of the board shown that hold the property, as of the last commit: what a
    /// change is compared with, to tell which went private.
    private(set) var publicIDs: Set<ShapeID> = []
    /// The public shapes of boards shown lately, for going back to them without looking through
    /// their shapes again.
    private var kept = BoardStash<Set<ShapeID>>()
    /// Following Topology: the chips and rows of what stands for a shape, or stands in, are made
    /// again as the edges change.
    private var following: TopologyFollowing?

    /// Whether a shape may be stood for: `public: true`, or a kind whose every shape is public, and
    /// not a stand-in (a stand-in is never stood for). Pure, and safe off the main actor.
    public let admitting: @Sendable (AnyShapeRecord) -> Bool

    #if DEBUG
    /// How many times a whole board has been looked through for its public shapes, and how many times
    /// `admitting` was made (debug builds).
    private(set) var boardsScanned = 0
    private(set) var admittingMade = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        topology = editor.topology
        let registry = editor.registry
        let always = Set(registry.kinds.filter { registry.definition(for: $0) is any AlwaysPublic })
        let standIns = topology?.standInKinds ?? []
        admitting = { record in
            !standIns.contains(record.kind) && (always.contains(record.kind) || record[PublicProperty.self] == true)
        }
        #if DEBUG
        admittingMade = 1
        #endif
        publicIDs = publicShapes(in: editor.document)
        following = topology?.follow { [weak self] change in self?.follow(change) }
    }

    private func publicShapes(in document: CanvasDocument) -> Set<ShapeID> {
        #if DEBUG
        boardsScanned += 1
        #endif
        return Set(document.shapes.lazy.filter { $0[PublicProperty.self] == true }.map(\.id))
    }

    /// Adornments' fades, found once: a commit asks about every shape it deletes, and a frame about
    /// every shape in view.
    private lazy var fade: ChipFade? = editor.service(ChipFade.self)

    // MARK: What stands for a shape

    /// How many things stand for the shape now (`topology.standIns(for:)`): direct and dynamic alike.
    func count(for id: ShapeID) -> Int { topology?.standIns(for: id).count ?? 0 }

    /// Whether anything stands for the shape: what holds it public.
    public func isHeld(_ id: ShapeID) -> Bool { !(topology?.standIns(for: id).isEmpty ?? true) }

    /// The shapes that stand for it, in the order they came to.
    public func standIns(for id: ShapeID) -> [ShapeID] { topology?.standIns(for: id) ?? [] }

    /// Whether the shape can be shown with a Referenced In tab: its kind can be public, and
    /// something stands for it.
    /// Observes the shape's edges, so a panel that asks redraws when that changes.
    func isReferenced(_ record: AnyShapeRecord) -> Bool {
        _ = topology?.revision(of: record.id)
        return editor.registry.canBePublic(record.kind) && isHeld(record.id)
    }

    // MARK: The chip

    /// How opaque a just-privatized shape's "Private" is: fully until it starts to fade, then less
    /// each frame. Nil for any other shape.
    func privateChipOpacity(of id: ShapeID) -> CGFloat? { fade?.opacity(of: PublicChip.self, on: id) }

    /// A click on a shape's chip: a public shape's makes it private, unless something stands for it
    /// (refused, as `makePrivate` does), and a just-privatized one's makes it public again.
    func click(_ id: ShapeID) {
        if publicIDs.contains(id) {
            _ = makePrivate([id])
        } else if fade?.isShowing(PublicChip.self, on: id) == true {
            editor.makePublic([id])
        }
    }

    // MARK: Making private

    /// `CanvasEditor.makePrivate`: the shapes nothing stands for go private in one step; the others
    /// shake, and the panel showing one shows what stands for it.
    func makePrivate(_ ids: [ShapeID]) -> [ShapeID] {
        let held = ids.filter(isHeld)
        let free = ids.filter { !held.contains($0) }
        if !free.isEmpty {
            editor.transact("Make Private") { transaction in
                for id in free { transaction.update(id) { $0[PublicProperty.self] = nil } }
            }
        }
        if !held.isEmpty {
            editor.refuseChanges(to: Set(held))
            showReferencedIn(held)
        }
        return held
    }

    /// The panel, if it shows this shape alone, goes to its Referenced In tab, which says why.
    private func showReferencedIn(_ held: [ShapeID]) {
        guard held.count == 1, let id = held.first, editor.selectedShapeIDs == [id], let record = editor.document[id] else { return }
        editor.detailPanel?.choose(.of(ReferencedInTab.self), for: record.kind)
    }

    // MARK: Following edges

    /// A shape's stand-ins changed (one came or went, or was re-pointed): what the shape and the
    /// shapes standing for it show of that is made again, on the canvas and in the list.
    private func follow(_ change: TopologyChange) {
        guard let ids = change.touchedByType[StandingEdge.id], !ids.isEmpty else { return }
        editor.adornmentsDidChange(for: ids)
        editor.contentsDidChange(for: ids)
    }
}

extension PublishingState: EditorService {
    /// Keeps which shapes are public, and shows "Private" on each shape the commit makes private. The
    /// chips it shows or takes back are told to Adornments once, at the end, since each tell has the
    /// select tool look again for a button under the pointer. A shape that only moved kept its
    /// value, so a drag reads none.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        var chipsChanged = Set<ShapeID>()
        let fade = fade
        for id in changes.removed {
            if !publicIDs.isEmpty { publicIDs.remove(id) }
            if fade?.hide(PublicChip.self, on: id) == true { chipsChanged.insert(id) }
        }
        let document = editor.document
        func look(at id: ShapeID) {
            if document[id]?[PublicProperty.self] == true {
                publicIDs.insert(id)
                if fade?.hide(PublicChip.self, on: id) == true { chipsChanged.insert(id) }
            } else if !publicIDs.isEmpty, publicIDs.remove(id) != nil {
                fade?.show(PublicChip.self, on: id)
                chipsChanged.insert(id)
            }
        }
        for id in changes.added { look(at: id) }
        for id in changes.changed where !changes.moved.contains(id) { look(at: id) }
        if !chipsChanged.isEmpty { editor.adornmentsDidChange(for: chipsChanged) }
    }

    /// The board left's public shapes are kept for when it's shown again.
    public func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
        guard old != new else { return }
        kept.keep(publicIDs, for: old, in: editor)
    }

    /// Another board is shown: its public shapes are the ones to tell going private by (as they were
    /// kept, if the board hasn't changed since it was left, else looked for).
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        publicIDs = kept.take(for: change.to, in: editor) ?? publicShapes(in: editor.document)
    }
}

#if DEBUG
extension CanvasEditor {
    /// How many times Publishing has looked through a whole board for its public shapes, and how
    /// many times it made `admitting` (debug builds only), so tests can hold going back to a board to
    /// taking back what was kept of it, and `admitting` to once per editor.
    public var boardsScannedForPublic: Int { publishing?.boardsScanned ?? 0 }
    public var admittingMade: Int { publishing?.admittingMade ?? 0 }
}
#endif
