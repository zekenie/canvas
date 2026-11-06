import Adornments
import Canvas
import CoreGraphics
import DetailPanel
import Neighbors
import Selection
import Topology

/// Per editor: the chips showing the open eye for a moment after a shape went public (a `ChipFade`;
/// the shake a refused try gives is Selection's `RefusalShake`), and what stands for a shape, asked of
/// Topology when a shape is to go private. Which shapes are private is the records', and what a commit
/// made public it tells from what the shape was before it (`ChangeSet.before`), so it keeps no copy of
/// them.
///
/// `admitting` is what a query engine, or anything that works off the main actor, asks of a shape
/// to know whether it may be stood for: built once, when the editor is, from the kinds that hold the
/// property, the kinds that are always public and the kinds that stand in (which are never stood
/// for, as Topology says).
@MainActor
public final class PublishingState {
    unowned let editor: CanvasEditor

    /// Whether a shape may be stood for: public (of a kind that holds the property and not private,
    /// or of a kind whose every shape is public), and not a stand-in (a stand-in is never stood for).
    /// Pure, and safe off the main actor.
    public let admitting: @Sendable (AnyShapeRecord) -> Bool
    /// Whether a shape `admitting` turns away would be admitted once made public: private, of a kind
    /// that holds the property, not kept aside, and not a stand-in. What Make Public changes, so what a
    /// query that stands for public shapes alone holds back. Pure, and safe off the main actor.
    public let admittable: @Sendable (AnyShapeRecord) -> Bool

    #if DEBUG
    /// How many times `admitting` was made (debug builds).
    private(set) var admittingMade = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        topology = editor.topology
        fade = editor.service(ChipFade.self)
        let registry = editor.registry
        let kinds = registry.privacyKinds
        let standIns = topology?.standInKinds ?? []
        admitting = { record in !standIns.contains(record.kind) && kinds.admits(record) }
        let holding = kinds.holding.subtracting(standIns)
        admittable = { record in
            holding.contains(record.kind) && record[PrivateProperty.self] == true && !record.isOpaque
        }
        #if DEBUG
        admittingMade = 1
        #endif
    }

    /// Topology and Adornments' fades, found once, as this is made, so they take each change in first: a commit asks
    /// the fades about every shape it deletes, and a frame about every shape in view.
    private let topology: TopologyIndex?
    private let fade: ChipFade?

    // MARK: What stands for a shape

    /// Whether anything stands for the shape: what keeps it from going private.
    public func isHeld(_ id: ShapeID) -> Bool { !(topology?.standIns(for: id).isEmpty ?? true) }

    /// The shapes that stand for it, in the order they came to.
    public func standIns(for id: ShapeID) -> [ShapeID] { topology?.standIns(for: id) ?? [] }

    // MARK: The chip

    /// How opaque a just-published shape's open eye is: fully until it starts to fade, then less
    /// each frame. Nil for any other shape.
    func publicChipOpacity(of id: ShapeID) -> CGFloat? { fade?.opacity(of: PrivateChip.self, on: id) }

    /// A click on a shape's chip, a try of the command its face shows (`attempt`): a private shape's
    /// Make Public, and a just-published one's Make Private, refused while something stands for it (it
    /// shakes, and the panel shows what holds it).
    func click(_ id: ShapeID) {
        if editor.document[id]?[PrivateProperty.self] == true {
            editor.attempt(.makePublic, on: [id])
        } else if fade?.isShowing(PrivateChip.self, on: id) == true {
            editor.attempt(.makePrivate, on: [id])
        }
    }

    // MARK: Making private

    /// `CanvasEditor.makePrivate`: the shapes nothing stands for go private in one step; the others
    /// shake, and the panel showing one shows what stands for it. A shape of a kind that holds no
    /// `private` is passed over.
    func makePrivate(_ ids: [ShapeID]) -> [ShapeID] {
        let held = ids.filter(isHeld)
        let registry = editor.registry
        let free = ids.filter { id in !held.contains(id) && editor.document[id].map { registry.holdsPrivate($0.kind) && !$0.isOpaque } == true }
        if !free.isEmpty {
            editor.transact("Make Private") { transaction in
                for id in free { transaction.update(id) { $0[PrivateProperty.self] = true } }
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
}

extension PublishingState: EditorService {
    /// Shows the open eye on each shape the commit makes public (private before it, and not now), and takes it back
    /// from each it makes private or deletes. The chips it shows or takes back are told to Adornments once, at the
    /// end, since each tell has the select tool look again for a button under the pointer. A shape that only moved
    /// kept its value, so a drag reads none; a paste that arrives public was private nowhere before.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        var chipsChanged = Set<ShapeID>()
        for id in changes.removed where fade?.hide(PrivateChip.self, on: id) == true { chipsChanged.insert(id) }
        let document = editor.document
        for id in changes.edited {
            guard let record = document[id] else { continue }
            if record[PrivateProperty.self] == true {
                if fade?.hide(PrivateChip.self, on: id) == true { chipsChanged.insert(id) }
            } else if !changes.added.contains(id), changes.before(id)?[PrivateProperty.self] == true {
                fade?.show(PrivateChip.self, on: id)
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
