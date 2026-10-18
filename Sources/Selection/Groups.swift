import AppKit
import Canvas
import CoreGraphics

/// Shapes that are selected as one: a plugin's groups (Grouping's), which the select tool takes
/// whole, as tldraw's does. A click on a shape in a group selects the group, all of it; a click on a
/// shape of a group that's selected, or a double-click, selects the part of it under the pointer, one
/// level in, and the selection is then inside the group (`editor.selectionFocus`, tldraw's focused
/// group, drawn as a dashed box), where a click selects its parts and Escape goes back out a level,
/// selecting the group whole. The marquee and the hover take groups whole too. Selection knows only
/// what the source says: the groups a shape is in, and a group's shapes, on the board shown. At most
/// one plugin says.
public enum SelectionGroups: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (CanvasEditor) -> (any SelectionGroupSource)?
    public static var owner: PluginID { .selection }
    public static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["the groups selected as one"] }
}

/// What says which shapes are selected as one (`SelectionGroups`), on the board shown.
@MainActor
public protocol SelectionGroupSource: AnyObject {
    /// The groups the shape is in, outermost first; none for a shape in no group. A group is any
    /// value that tells it from the others.
    func groups(of id: ShapeID) -> [AnyHashable]
    /// The shapes a group holds, at any depth, back to front; none for one that is no group.
    func shapes(in group: AnyHashable) -> [ShapeID]
}

extension PluginRegistrar {
    /// Which shapes are selected as one (see `SelectionGroups`): `source` gives an editor's groups,
    /// asked for the first time the selection needs them (again while it gives none: a service made
    /// after Selection's). Tell the editor when they change (`editor.selectionGroupsDidChange()`).
    public mutating func selectionGroups(_ source: @escaping @MainActor (CanvasEditor) -> (any SelectionGroupSource)?) {
        contribute(source, to: SelectionGroups.self)
    }
}

extension SelectionState {
    /// Where the groups come from (`SelectionGroups`): found once, or none.
    var groupSource: (any SelectionGroupSource)? {
        if let found = groupSourceFound { return found }
        guard let contribution = editor.registry.contributions(to: SelectionGroups.self).first?.value else {
            groupSourceFound = .some(nil)
            return nil
        }
        // Not made yet (asked while the editor makes its services): asked again next time.
        guard let source = contribution(editor) else { return nil }
        groupSourceFound = .some(source)
        return source
    }

    /// The groups a shape is in, outermost first.
    func groups(of id: ShapeID) -> [AnyHashable] { groupSource?.groups(of: id) ?? [] }

    /// A group's shapes that can be selected, back to front.
    func members(of group: AnyHashable) -> [ShapeID] { (groupSource?.shapes(in: group) ?? []).filter(isSelectable(id:)) }

    /// What a click on `id` selects, with the selection inside `focus`: the outermost group it's in
    /// past the groups it shares with `focus`, all of it, or the shape alone when it's in no group
    /// past them (tldraw's getOutermostSelectableShape).
    func unit(of id: ShapeID, within focus: [AnyHashable]) -> [ShapeID] {
        let path = groups(of: id)
        let shared = path.sharedPrefixCount(with: focus)
        guard shared < path.count else { return [id] }
        let shapes = members(of: path[shared])
        return shapes.contains(id) ? shapes : [id]
    }

    /// What a click on `id` selects once what `unit(of:within:)` gives is selected: the part of it
    /// under the pointer, one level in.
    func unit(inside id: ShapeID, within focus: [AnyHashable]) -> [ShapeID] {
        let path = groups(of: id)
        let shared = path.sharedPrefixCount(with: focus)
        guard shared + 1 < path.count else { return [id] }
        let shapes = members(of: path[shared + 1])
        return shapes.contains(id) ? shapes : [id]
    }

    /// What a selection is inside: the groups all its shapes are in, outermost first, less those it
    /// holds whole (a group selected is the selection, not what it's inside).
    func focus(of selection: [ShapeID], selected: Set<ShapeID>) -> [AnyHashable] {
        guard groupSource != nil else { return [] }
        return selection.lazy.map(groups(of:)).groupsInside { members(of: $0).allSatisfy(selected.contains) }
    }

    /// The shapes a marquee selects for those it reaches (`hits`, back to front): each with what a
    /// click on it would select with the selection inside `focus` (its group, whole), and with
    /// `mustContain` (⌘) a group only if the marquee holds every one of its shapes. Each once.
    func units(of hits: [ShapeID], mustContain: Bool, within focus: [AnyHashable]) -> [ShapeID] {
        guard groupSource != nil else { return hits }
        let reached = mustContain ? Set(hits) : []
        var seen = Set<ShapeID>(), units: [ShapeID] = []
        for id in hits where !seen.contains(id) {
            let unit = unit(of: id, within: focus)
            seen.formUnion(unit)
            if mustContain, !unit.allSatisfy(reached.contains) { continue }
            units += unit
        }
        return units
    }

    /// A click on `hit` released without a drag, that didn't select on its press (tldraw's
    /// PointingShape.onPointerUp): on a shape of a group that's selected, the part of it under the
    /// pointer, one level in (with ⇧ or ⌘, that part in the group's place); otherwise what a click
    /// on it selects, alone, or, with ⇧ or ⌘, added to the selection or taken from it.
    func release(on hit: ShapeID, additive: Bool) {
        let unit = unit(of: hit, within: focus)
        let isSelected = unit.allSatisfy(selectedSet.contains)
        if unit == [hit] {
            if isSelected {
                select(additive ? selectedIDs.filter { $0 != hit } : [hit])
            } else {
                select(additive ? selectedIDs + [hit] : [hit])
            }
        } else if isSelected {
            let inside = self.unit(inside: hit, within: focus)
            let gone = Set(unit)
            select(additive ? selectedIDs.filter { !gone.contains($0) } + inside : inside)
        } else {
            select(additive ? selectedIDs + unit : unit)
        }
    }

    /// The release of a press on empty canvas, or on empty space in the box around several, onto
    /// `hit` (tldraw's selectOnCanvasPointerUp): with ⇧ or ⌘, what a click on it selects is added to
    /// the selection, or taken from it; otherwise it's selected, unless it is already.
    func canvasRelease(on hit: ShapeID, additive: Bool) {
        let unit = unit(of: hit, within: focus)
        let isSelected = unit.allSatisfy(selectedSet.contains)
        if additive {
            let gone = Set(unit)
            select(isSelected ? selectedIDs.filter { !gone.contains($0) } : selectedIDs + unit)
        } else if !isSelected {
            select(unit)
        }
    }

    /// Escape with nothing under way: out of the group the selection is inside, selecting it whole
    /// (tldraw's popFocusedGroupId), or, with nothing selected there, out of it altogether; with the
    /// selection in no group, nothing selected.
    func escape() {
        guard let innermost = focus.last else { return select([]) }
        guard !selectedIDs.isEmpty else {
            focus = []
            return
        }
        select(members(of: innermost))
    }

    /// A press on empty canvas outside the box of the group the selection is inside leaves it
    /// (tldraw's, on the release; here on the press, so a marquee from there takes groups whole).
    func leaveFocus(unlessInside point: CGPoint) {
        guard let box = focusBox, box.contains(point) else {
            focus = []
            return
        }
    }

    /// The box around the innermost group the selection is inside, in world units: what's drawn
    /// dashed. Nil when the selection is in no group.
    var focusBox: CGRect? {
        guard let innermost = focus.last else { return nil }
        return editor.shapeContext.bounds(of: members(of: innermost))
    }

    /// The source's groups changed: what the selection is inside is worked out again, and an empty
    /// selection keeps the groups of it that are still groups.
    func groupsDidChange() {
        guard selectedIDs.isEmpty else { return focus = focus(of: selectedIDs, selected: selectedSet) }
        focus = Array(focus.prefix { !members(of: $0).isEmpty })
    }
}

extension CanvasEditor {
    /// What a click on the shape would select now: the outermost group it's in past the groups the
    /// selection is inside (`SelectionGroups`), all of it, or the shape alone. Without groups, the
    /// shape. A right-click selects it for its menu.
    public func selectionUnit(of id: ShapeID) -> [ShapeID] {
        guard let state = selectionState else { return [id] }
        return state.unit(of: id, within: state.focus)
    }

    /// The groups the selection is inside, outermost first (`SelectionGroups`, tldraw's focused
    /// group): a click in them selects their parts. Empty when it's in none.
    public var selectionFocus: [AnyHashable] { selectionState?.focus ?? [] }

    /// Tells the selection that the groups changed (`SelectionGroups`): the source calls it once it
    /// has heard a commit that changed them, so what the selection is inside is worked out again.
    public func selectionGroupsDidChange() { selectionState?.groupsDidChange() }

    /// Whether every one of these shapes is selected: O(their count). Without the Selection plugin, false.
    public func areSelected(_ ids: [ShapeID]) -> Bool {
        guard let state = selectionState else { return false }
        return ids.allSatisfy(state.selectedSet.contains)
    }
}

/// The box around the group the selection is inside (`SelectionGroups`), dashed, as tldraw draws a
/// focused group: a click inside it selects a part of the group, and Escape leaves it. In the select
/// tool, stood off what it holds past their outlines.
struct GroupFocusOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in overlay: OverlayContext) {
        let editor = overlay.editor
        guard editor.currentToolID == .select, let box = editor.selectionState?.focusBox, !box.isNull else { return }
        let zoom = overlay.zoom, standoff = SelectionStyle.groupFocusStandoff / zoom
        let rect = box.insetBy(dx: -standoff, dy: -standoff)
        guard rect.intersects(overlay.visibleRect) else { return }
        let cg = overlay.cg
        cg.saveGState()
        cg.setStrokeColor(SelectionStyle.groupFocusStroke.cgColor)
        cg.setLineWidth(SelectionStyle.groupFocusStrokeWidth / zoom)
        cg.setLineDash(phase: 0, lengths: SelectionStyle.groupFocusDash.map { $0 / zoom })
        cg.stroke(rect)
        cg.restoreGState()
    }
}

extension Sequence {
    /// The groups shapes are all inside, given each one's (`self`, outermost first): those their paths
    /// share from the start, less the innermost ones they hold whole (`holdsWhole`): a group held
    /// whole is the shapes, not what they're inside. Selection's focus and Grouping's Group go by it,
    /// so a new group goes where the selection is drawn inside. Stops reading paths once none is
    /// shared.
    public func groupsInside<Group: Hashable>(holdsWhole: (Group) -> Bool) -> [Group] where Element == [Group] {
        var iterator = makeIterator()
        guard var shared = iterator.next() else { return [] }
        while !shared.isEmpty, let path = iterator.next() { shared.removeLast(shared.count - path.sharedPrefixCount(with: shared)) }
        while let innermost = shared.last, holdsWhole(innermost) { shared.removeLast() }
        return shared
    }
}

extension Array where Element: Equatable {
    /// How many elements this and `other` have alike from the start.
    func sharedPrefixCount(with other: [Element]) -> Int {
        var count = 0
        while count < self.count, count < other.count, self[count] == other[count] { count += 1 }
        return count
    }
}
