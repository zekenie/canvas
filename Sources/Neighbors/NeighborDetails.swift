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
                    NeighborListView(subject: shape.shapeID, list: shape.service(NeighborList.self))
                }
                // Going to what's connected changes nothing of the shape.
                .enabledWhileReadOnly()
            }
        }
    }
}

/// The tab of what's connected to a shape. Always there, on every shape: its lists are read once
/// it shows, a turn or so after, and a tab that came with them would come late.
public enum NeighborsTab {}

extension NeighborsTab: DetailTab {
    public static var title: String { NeighborStyle.tab }
    public static var order: Int { NeighborStyle.tabOrder }
}

/// The lists of one shape. It tells the service which shape's lists are on screen, so the engine is
/// asked only while they are, and observes the answer. Until the service has heard (a panel is drawn
/// once before it appears) the lists it holds are another shape's, or none: nothing is shown of them.
struct NeighborListView: View {
    let subject: ShapeID
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

/// The search field, once the lists are long, then each list that has shapes: its head, which folds
/// it, and its rows, made as they scroll into view.
struct NeighborLists: View {
    let list: NeighborList

    var body: some View {
        let searching = !list.search.isEmpty
        let lists = list.groups.indices.map { (group: $0, shown: list.shown(in: $0)) }.filter { $0.shown.count > 0 }
        let stamp = list.listing?.stamp ?? 0
        VStack(alignment: .leading, spacing: NeighborStyle.spacing) {
            if searching || list.total >= NeighborStyle.searchFrom {
                DetailSearchField(NeighborStyle.searchPrompt, text: Binding(get: { list.search }, set: { list.setSearch($0) }))
            }
            if lists.isEmpty {
                // Nothing said until the answer is in: most shapes have something.
                if list.hasLanded {
                    Text(searching ? NeighborStyle.noMatches : NeighborStyle.empty)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lists, id: \.group) { listed in
                        let group = list.groups[listed.group]
                        // Searching unfolds every list, so its head folds nothing then.
                        DetailGroupHeader(group.title, count: listed.shown.count, tint: group.color, isCollapsed: !list.showsRows(of: listed.group)) {
                            list.setFolded(listed.group, !list.isFolded(listed.group))
                        }
                        .padding(.top, listed.group == lists.first?.group ? 0 : NeighborStyle.groupSpacing)
                        ForEach(listed.shown.rows) { row in
                            NeighborRowView(list: list, group: listed.group, row: row, stamp: stamp).equatable()
                        }
                    }
                }
            }
        }
    }
}

/// One shape: the pointer on it hovers it on the canvas (its card, if it's on another board), and a
/// click goes to it.
struct NeighborRowView: View, Equatable {
    let list: NeighborList
    let group: Int
    let row: NeighborRow
    /// The answer it was drawn for: its name and its caption are read here.
    let stamp: Int

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.group == b.group && a.row == b.row && a.stamp == b.stamp
    }

    var body: some View {
        let id = row.id
        let line = list.line(for: row, in: group)
        Button { list.go(to: id) } label: {
            DetailShapeRow(symbol: line.symbol, tint: line.tint, name: line.name, detail: line.detail, lines: line.caption.map { [$0] } ?? [])
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.bottom, line.caption == nil ? 0 : NeighborStyle.captionedRowBottom)
        .onHover { inside in
            if inside { list.hover(id) } else { list.endHover(id) }
        }
        .onDisappear { list.endHover(id) }
    }
}
