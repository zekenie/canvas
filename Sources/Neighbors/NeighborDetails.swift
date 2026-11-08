import AppKit
import Canvas
import DetailPanel
import SwiftUI

extension PluginID {
    public static let neighborDetails: PluginID = "neighbor-details"
}

/// What's connected to a shape, in its panel: one tab, on every shape, of lists by how. Each light's
/// matches under its title, headed by the light's color (so the tab is the key to what hovering
/// outlines), then what the shape is inside and what it holds. A plugin value of its own, after
/// Neighbors and the detail panel, so a list without the panel leaves it out and keeps the lights;
/// one with it and no panel is refused (`ownerNotInstalled`).
public struct NeighborDetailsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .neighborDetails }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { NeighborList(editor: $0, lights: $0.registry.neighborLights) }
        // Every shape is inside something, holds something or is connected: the tab is on every shape.
        registrar.forEveryShape { every in
            every.details {
                DetailSection<AnyShapeRecord>(in: NeighborsTab.self, id: "neighbors") { shape in
                    NeighborListView(subject: PartAddress(shape.shapeID), list: shape.service(NeighborList.self))
                }
                // Going to what's connected changes nothing of the shape.
                .enabledWhileReadOnly()
            }
        }
        // A row of a kind with rows, selected as the panel's subject, has the tab too: its own connections, from the lights that
        // serve rows, beside the row's own tab its kind gives.
        registrar.forShapes(adopting: .parts) { parted in
            parted.rowDetails(in: NeighborsTab.self, id: "neighbors") { row in
                NeighborListView(subject: row.address, list: row.service(NeighborList.self))
            }
        }
    }
}

/// The tab of what's connected to a shape. Always there, on every shape: its lists are read once
/// it shows, a turn or so after, and a tab that came with them would come late. Where it first
/// appears: after a kind's own tabs and the feature tabs of the plugins before it, before Style.
public enum NeighborsTab {}

extension NeighborsTab: DetailTab {
    public static var title: String { NeighborStyle.tab }
}

/// The lists of one shape. It tells the service which shape's lists are on screen, so the engine is
/// asked only while they are, and observes the answer. Until the service has heard (a panel is drawn
/// once before it appears) the lists it holds are another shape's, or none: nothing is shown of them.
struct NeighborListView: View {
    let subject: PartAddress
    let list: NeighborList?

    var body: some View {
        if let list {
            // A stack that's there with nothing in it, so it appears, and says so, before it has lists.
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 0)
                if list.subject == subject { NeighborLists(list: list) }
            }
            .onAppear { list.watch(subject) }
            .onDisappear { list.unwatch(subject) }
        }
    }
}

/// What a line of the lists is: a list's head, or one of its rows.
enum NeighborItemID: Hashable, Sendable {
    case head(Int)
    case row(group: Int, shape: ShapeID)
}

/// The search field, once the lists are long, then one list of rows (`DetailRowList`: a stop of Tab,
/// walked with the arrows): each list that has shapes has its head, which folds it, and its rows,
/// made as they scroll into view. The row the keys are on lights what it stands for on the canvas, as
/// the pointer on it does.
struct NeighborLists: View {
    let list: NeighborList
    @State private var handle = DetailListHandle()

    var body: some View {
        let searching = !list.search.isEmpty
        let lists = list.order.map { (group: $0, shown: list.shown(in: $0)) }.filter { $0.shown.count > 0 }
        let stamp = list.listing?.stamp ?? 0
        VStack(alignment: .leading, spacing: NeighborStyle.spacing) {
            if searching || list.total >= NeighborStyle.searchFrom {
                DetailSearchField(NeighborStyle.searchPrompt, text: Binding(get: { list.search }, set: { list.setSearch($0) }), list: handle)
            }
            if lists.isEmpty {
                // Nothing said until the answer is in: most shapes have something.
                if list.hasLanded {
                    Text(searching ? NeighborStyle.noMatches : NeighborStyle.empty)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                let (items, rows) = items(of: lists)
                DetailRowList(items, label: NeighborStyle.tab, handle: handle, onHighlight: { id in highlight(id) }) { item in
                    switch item.id {
                    case .head(let group):
                        let shown = list.shown(in: group).count
                        let isFolded = !list.showsRows(of: group)
                        DetailGroupHeader(list.groups[group].title, count: shown, tint: list.groups[group].color, isCollapsed: isFolded, isRow: true) {}
                            .detailRowAccessibility(label: list.groups[group].title, value: DetailGroupHeader.spoken(count: shown, isCollapsed: isFolded),
                                                    activate: item.activate)
                    case .row(let group, _):
                        if let row = rows[item.id] {
                            NeighborRowView(list: list, group: group, row: row, stamp: stamp, activate: item.activate).equatable()
                        }
                    }
                }
            }
        }
    }

    /// Each list's head, then its rows while it shows them (and the rows by line). Searching unfolds
    /// every list, so its head folds nothing then.
    private func items(of lists: [(group: Int, shown: (count: Int, rows: [NeighborRow]))])
        -> ([DetailRowItem<NeighborItemID>], [NeighborItemID: NeighborRow]) {
        var items: [DetailRowItem<NeighborItemID>] = [], rows: [NeighborItemID: NeighborRow] = [:]
        for listed in lists {
            let group = listed.group, isFolded = !list.showsRows(of: group)
            items.append(DetailRowItem(id: .head(group), kind: .head(isFolded: isFolded)) { list.setFolded(group, !list.isFolded(group)) })
            for row in listed.shown.rows {
                let id = NeighborItemID.row(group: group, shape: row.id)
                rows[id] = row
                items.append(DetailRowItem(id: id, parent: .head(group), height: rowHeight(group)) { list.go(to: row.id) })
            }
        }
        return (items, rows)
    }

    /// A row with a caption is taller by it: read the way the row draws it, once.
    private func rowHeight(_ group: Int) -> CGFloat {
        DetailRowItem<NeighborItemID>.height(captionLines: list.groups[group].caption == nil ? 0 : 1)
    }

    /// The row the keys are on lights its shape as the pointer on the row does; nothing is lit once
    /// the keyboard leaves the list.
    private func highlight(_ id: NeighborItemID?) {
        if let lit = lit { list.endHover(lit) }
        lit = nil
        guard case .row(_, let shape)? = id else { return }
        lit = shape
        list.hover(shape)
    }

    @State private var lit: ShapeID?
}

/// One shape: the pointer on it hovers it on the canvas (its card, if it's on another board), and a
/// click goes to it; so do Return and Space on it in the list.
struct NeighborRowView: View, Equatable {
    let list: NeighborList
    let group: Int
    let row: NeighborRow
    /// The answer it was drawn for: its name and its caption are read here.
    let stamp: Int
    let activate: @MainActor () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.group == b.group && a.row == b.row && a.stamp == b.stamp
    }

    var body: some View {
        let id = row.id
        let line = list.line(for: row, in: group)
        DetailShapeRow(symbol: line.symbol, tint: line.tint, name: line.name, detail: line.detail, place: line.place, lines: line.caption.map { [$0] } ?? [])
            .foregroundStyle(.primary)
            .detailRowAccessibility(label: line.spoken, activate: activate)
            .onHover { inside in
                if inside { list.hover(id) } else { list.endHover(id) }
            }
            .onDisappear { list.endHover(id) }
    }
}
