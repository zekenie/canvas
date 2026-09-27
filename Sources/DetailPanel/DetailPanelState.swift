import Canvas
import Observation

/// What the panel shows for one shape, resolved from the frozen registry. The view renders it;
/// tests read it.
@MainActor
public struct DetailLayout {
    public let header: DetailHeader
    /// Only tabs with at least one section shown for this shape, sorted by `order`, then by first
    /// appearance (the kind's own contributions in plugin order, then every-box ones).
    public let tabs: [DetailTabID]
    let sectionsByTab: [DetailTabID: [ResolvedSection]]

    /// The tab's shown sections, in order: the kind's own, then every-box ones, each in plugin order.
    public func sections(in tab: DetailTabID) -> [DetailSectionKey] { resolved(in: tab).map(\.key) }

    func resolved(in tab: DetailTabID) -> [ResolvedSection] { sectionsByTab[tab] ?? [] }
}

struct ResolvedSection {
    let key: DetailSectionKey
    let section: ErasedSection
}

/// Per editor (so per window): each kind's contributions, gathered once (the registry is frozen),
/// the tab last chosen for each kind, and the collapsed sections. In memory only.
@MainActor
@Observable
public final class DetailPanelState {
    /// A kind's headers and sections, before `when` and sorting.
    private struct Candidates {
        let headers: [@MainActor (AnyShapeRecord) -> DetailHeader?]
        let sections: [ResolvedSection]
    }

    @ObservationIgnored private unowned let editor: CanvasEditor
    @ObservationIgnored private var candidates: [ShapeKind: Candidates] = [:]
    private var chosenTabs: [ShapeKind: DetailTabID] = [:]
    private var collapsed: Set<DetailSectionKey> = []

    init(editor: CanvasEditor) { self.editor = editor }

    public func layout(for record: AnyShapeRecord) -> DetailLayout {
        let all = candidates[record.kind] ?? resolve(record.kind)
        let shown = all.sections.filter { $0.section.isShown(record) }
        var firstSeen: [DetailTabID] = []
        for section in shown where !firstSeen.contains(section.key.tab) { firstSeen.append(section.key.tab) }
        let tabs = firstSeen.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element)
        return DetailLayout(header: header(for: record, from: all.headers), tabs: tabs,
                            sectionsByTab: Dictionary(grouping: shown, by: \.key.tab))
    }

    /// The kind's own contributions, then every kind's, each in plugin order. Once per kind: the
    /// registry is frozen.
    private func resolve(_ kind: ShapeKind) -> Candidates {
        let all = editor.registry.contributions(to: ShapeDetails.self)
        let ordered = all.filter { $0.target == .kind(kind) } + all.filter { $0.target == .any }
        let resolved = Candidates(
            headers: ordered.compactMap(\.value.header),
            sections: ordered.flatMap { contribution in
                contribution.value.sections.map {
                    ResolvedSection(key: DetailSectionKey(target: contribution.target, tab: $0.tab, section: $0.id), section: $0)
                }
            })
        candidates[kind] = resolved
        return resolved
    }

    /// The kind's header, else the label and symbol of the tool that places the kind, else the
    /// kind. A header without a symbol takes the tool's.
    private func header(for record: AnyShapeRecord, from headers: [@MainActor (AnyShapeRecord) -> DetailHeader?]) -> DetailHeader {
        let tool = editor.registry.tools.first { $0.id == ToolID(placing: record.kind) }
        var header = headers.lazy.compactMap { $0(record) }.first ?? DetailHeader(tool?.label ?? record.kind.rawValue)
        if header.systemImage == nil { header.systemImage = tool?.systemImage }
        return header
    }

    /// The kind's contributions, then every kind's, each in plugin order.
    public func statuses(for record: AnyShapeRecord) -> [DetailStatus] {
        let context = DetailContext(editor: editor)
        return editor.registry.contributions(to: DetailStatuses.self, for: record.kind).flatMap { $0(record, context) }
    }

    /// The tab last chosen for this kind if the layout has it, else the first. A shape that lacks
    /// the chosen tab doesn't forget it for the next shape that has it.
    public func currentTab(in layout: DetailLayout, for kind: ShapeKind) -> DetailTabID? {
        layout.tabs.first { $0 == chosenTabs[kind] } ?? layout.tabs.first
    }

    public func choose(_ tab: DetailTabID, for kind: ShapeKind) { chosenTabs[kind] = tab }

    /// Remembered by key: an every-box section collapses for every kind, a kind's own for that kind.
    public func isCollapsed(_ key: DetailSectionKey) -> Bool { collapsed.contains(key) }

    public func setCollapsed(_ key: DetailSectionKey, _ isCollapsed: Bool) {
        if isCollapsed { collapsed.insert(key) } else { collapsed.remove(key) }
    }
}

extension DetailPanelState: EditorService {}

extension CanvasEditor {
    /// The panel's state; nil without DetailPanelPlugin.
    public var detailPanel: DetailPanelState? { service(DetailPanelState.self) }
}
