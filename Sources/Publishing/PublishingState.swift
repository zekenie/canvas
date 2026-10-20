import Adornments
import Canvas
import CoreGraphics
import DetailPanel
import Neighbors
import Selection
import TableOfContents
import Topology

/// Per editor: what stands for each shape (read from Topology, which follows every change to the
/// edges, a commit's or a provide's), and the chips showing "Private" for a moment after a shape went
/// private (a `ChipFade`; the shake a refused try gives is Selection's `RefusalShake`). Which shapes
/// are public is the records', and what a commit made private it tells from what the shape was
/// before it (`ChangeSet.before`), so it keeps no copy of them.
///
/// `admitting` is what a query engine, or anything that works off the main actor, asks of a shape
/// to know whether it may be stood for: built once, when the editor is, from the kinds that are
/// always public and the kinds that stand in (which are never stood for, as Topology says), and the
/// property's key.
@MainActor
public final class PublishingState {
    unowned let editor: CanvasEditor
    /// Following Topology: the chips and rows of what stands for a shape, or stands in, are made
    /// again as the edges change.
    private var following: TopologyFollowing?

    /// Whether a shape may be stood for: `public: true`, or a kind whose every shape is public, and
    /// not a stand-in (a stand-in is never stood for). Pure, and safe off the main actor.
    public let admitting: @Sendable (AnyShapeRecord) -> Bool

    #if DEBUG
    /// How many times `admitting` was made (debug builds).
    private(set) var admittingMade = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        let topology = editor.topology
        self.topology = topology
        fade = editor.service(ChipFade.self)
        let registry = editor.registry
        let always = Set(registry.kinds.filter { registry.definition(for: $0) is any AlwaysPublic })
        let standIns = topology?.standInKinds ?? []
        admitting = { record in
            !standIns.contains(record.kind) && (always.contains(record.kind) || record[PublicProperty.self] == true)
        }
        #if DEBUG
        admittingMade = 1
        #endif
        following = topology?.follow { [weak self] change in self?.follow(change) }
    }

    /// Topology and Adornments' fades, found once, as this is made, so they take each change in first: a commit asks
    /// the fades about every shape it deletes, and a frame about every shape in view.
    private let topology: TopologyIndex?
    private let fade: ChipFade?

    // MARK: What stands for a shape

    /// How many things stand for the shape now (`topology.standIns(for:)`): direct and dynamic alike.
    func count(for id: ShapeID) -> Int { topology?.standIns(for: id).count ?? 0 }

    /// Whether anything stands for the shape: what holds it public.
    public func isHeld(_ id: ShapeID) -> Bool { !(topology?.standIns(for: id).isEmpty ?? true) }

    /// The shapes that stand for it, in the order they came to.
    public func standIns(for id: ShapeID) -> [ShapeID] { topology?.standIns(for: id) ?? [] }

    // MARK: The chip

    /// How opaque a just-privatized shape's "Private" is: fully until it starts to fade, then less
    /// each frame. Nil for any other shape.
    func privateChipOpacity(of id: ShapeID) -> CGFloat? { fade?.opacity(of: PublicChip.self, on: id) }

    /// A click on a shape's chip, a try of the command its face shows (`attempt`): a public shape's Make
    /// Private, refused while something stands for it (it shakes, and the panel shows what holds it), and
    /// a just-privatized one's Make Public.
    func click(_ id: ShapeID) {
        if editor.document[id]?[PublicProperty.self] == true {
            editor.attempt(.makePrivate, on: [id])
        } else if fade?.isShowing(PublicChip.self, on: id) == true {
            editor.attempt(.makePublic, on: [id])
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
            showWhatHolds(held)
        }
        return held
    }

    /// The panel, if it shows this shape alone, goes to the tab that lists what's connected to it
    /// (Neighbors'), where what stands for it is among what points to it: that says why.
    private func showWhatHolds(_ held: [ShapeID]) {
        guard held.count == 1, let id = held.first, editor.selectedShapeIDs == [id], let record = editor.document[id] else { return }
        editor.detailPanel?.choose(.of(NeighborsTab.self), for: record.kind)
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
    /// Shows "Private" on each shape the commit makes private (public before it, and not now), and takes it back
    /// from each it makes public or deletes. The chips it shows or takes back are told to Adornments once, at the
    /// end, since each tell has the select tool look again for a button under the pointer. A shape that only moved
    /// kept its value, so a drag reads none; a paste that arrives private was public nowhere before.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        var chipsChanged = Set<ShapeID>()
        for id in changes.removed where fade?.hide(PublicChip.self, on: id) == true { chipsChanged.insert(id) }
        let document = editor.document
        for id in changes.edited {
            if document[id]?[PublicProperty.self] == true {
                if fade?.hide(PublicChip.self, on: id) == true { chipsChanged.insert(id) }
            } else if !changes.added.contains(id), changes.before(id)?[PublicProperty.self] == true {
                fade?.show(PublicChip.self, on: id)
                chipsChanged.insert(id)
            }
        }
        if !chipsChanged.isEmpty { editor.adornmentsDidChange(for: chipsChanged) }
    }
}

#if DEBUG
extension CanvasEditor {
    /// How many times Publishing made `admitting` (debug builds only), so tests can hold it to once per editor.
    public var admittingMade: Int { publishing?.admittingMade ?? 0 }
}
#endif
