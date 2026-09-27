import Canvas
import Observation

/// What the panel shows for one shape, resolved from the frozen registry. The view renders it;
/// tests read it.
@MainActor
public struct DetailLayout {
    let resolvedHeader: ResolvedHeader
    /// What the panel calls the shape's kind: the label of the tool that places it, else the kind.
    /// A header field's placeholder, by default (`DetailHeaderField`).
    public let kindName: String
    /// The symbol of the tool that places the kind, which a header without its own shows.
    let kindSymbol: String?
    /// Only tabs with at least one section shown for this shape, or a status line, sorted by
    /// `order`, then by first appearance (the kind's own contributions in plugin order, then
    /// every-box ones, then status lines').
    public let tabs: [DetailTabID]
    let sectionsByTab: [DetailTabID: [ResolvedSection]]
    let statusesByTab: [DetailTabID: [DetailStatus]]

    /// The header when it's a `DetailHeader` (the kind's own, or the tool's label a kind without
    /// one gets), as shown: without a symbol of its own, with its kind's. Nil for a header of
    /// another type, which `header(as:)` reads.
    public var header: DetailHeader? {
        guard var header = header(as: DetailHeader.self) else { return nil }
        if header.systemImage == nil { header.systemImage = kindSymbol }
        return header
    }

    /// The header as the view the kind built (`header(as: TitleHeader.self)`); nil if it's of
    /// another type.
    public func header<Header>(as _: Header.Type) -> Header? { resolvedHeader.value as? Header }

    /// The tab's shown sections, in order: the kind's own, then every-box ones, each in plugin order.
    public func sections(in tab: DetailTabID) -> [DetailSectionKey] { resolved(in: tab).map(\.key) }

    func resolved(in tab: DetailTabID) -> [ResolvedSection] { sectionsByTab[tab] ?? [] }

    /// The tab's status lines (`DetailStatuses`), shown above its sections: the kind's
    /// contributions, then every kind's, each in plugin order.
    public func statuses(in tab: DetailTabID) -> [DetailStatus] { statusesByTab[tab] ?? [] }
}

/// A shape's status lines, where they go: what the panel redraws for when they change.
struct ShapeStatuses: Equatable {
    struct TabLines: Equatable {
        let tab: DetailTabID
        var lines: [DetailStatus]
    }

    var footer: [DetailStatus] = []
    /// Only tabs with lines, in the order of their first contribution.
    var tabs: [TabLines] = []
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
        let headers: [@MainActor (AnyShapeRecord, CanvasEditor) -> ResolvedHeader?]
        let sections: [ResolvedSection]
    }

    @ObservationIgnored private unowned let editor: CanvasEditor
    @ObservationIgnored private var candidates: [ShapeKind: Candidates] = [:]
    private var chosenTabs: [ShapeKind: DetailTabID] = [:]
    private var collapsed: Set<DetailSectionKey> = []

    init(editor: CanvasEditor) { self.editor = editor }

    public func layout(for record: AnyShapeRecord) -> DetailLayout {
        layout(for: record, statuses: statuses(of: record).tabs)
    }

    /// With the shape's status lines for tabs, read already.
    func layout(for record: AnyShapeRecord, statuses: [ShapeStatuses.TabLines]) -> DetailLayout {
        let all = candidates[record.kind] ?? resolve(record.kind)
        let shown = all.sections.filter { $0.section.isShown(record) }
        var firstSeen: [DetailTabID] = []
        for tab in shown.map(\.key.tab) + statuses.map(\.tab) where !firstSeen.contains(tab) { firstSeen.append(tab) }
        let tabs = firstSeen.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element)
        // The kind's header, else the label of the tool that places the kind, else the kind.
        let tool = placingTool(of: record.kind)
        let name = tool?.label ?? record.kind.rawValue
        let header = all.headers.lazy.compactMap { [editor] in $0(record, editor) }.first ?? ResolvedHeader(DetailHeader(name))
        return DetailLayout(resolvedHeader: header, kindName: name, kindSymbol: tool?.systemImage, tabs: tabs,
                            sectionsByTab: Dictionary(grouping: shown, by: \.key.tab),
                            statusesByTab: Dictionary(uniqueKeysWithValues: statuses.map { ($0.tab, $0.lines) }))
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

    /// The header shown when several shapes are selected: "N Shapes", with each kind's name once,
    /// in selection order ("Sticky Note, Arrow"), and stacked squares. A kind's name is the label
    /// of the tool that places it, else the kind.
    public func selectionSummary(of records: [AnyShapeRecord]) -> DetailHeader {
        var names: [String] = []
        for record in records {
            let name = placingTool(of: record.kind)?.label ?? record.kind.rawValue
            if !names.contains(name) { names.append(name) }
        }
        return DetailHeader("\(records.count) Shapes", subtitle: names.joined(separator: ", "), systemImage: "square.on.square")
    }

    private func placingTool(of kind: ShapeKind) -> ToolDescriptor? {
        editor.registry.tools.first { $0.id == ToolID(placing: kind) }
    }

    /// The footer's lines: the kind's contributions, then every kind's, each in plugin order. A
    /// tab's are in the layout (`statuses(in:)`).
    public func statuses(for record: AnyShapeRecord) -> [DetailStatus] { statuses(of: record).footer }

    /// Every status line of the shape, footer and tabs: the kind's contributions, then every
    /// kind's, each in plugin order.
    func statuses(of record: AnyShapeRecord) -> ShapeStatuses {
        let context = DetailContext(editor: editor)
        var statuses = ShapeStatuses()
        for contribution in editor.registry.contributions(to: DetailStatuses.self, for: record.kind) {
            let lines = contribution.make(record, context)
            guard !lines.isEmpty else { continue }
            guard let tab = contribution.tab else {
                statuses.footer += lines
                continue
            }
            if let i = statuses.tabs.firstIndex(where: { $0.tab == tab }) {
                statuses.tabs[i].lines += lines
            } else {
                statuses.tabs.append(ShapeStatuses.TabLines(tab: tab, lines: lines))
            }
        }
        return statuses
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
