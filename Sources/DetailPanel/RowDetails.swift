import AppKit
import Canvas
import Chrome
import Palette
import Selection
import SwiftUI

// A row as the panel's subject: one shape selected with exactly one of its rows (a part, `PartedShape`) selected as an item of it,
// or the one its editing has the keys on (`editor.editingPart`). The panel then shows the row's own: a header that is the row (its
// lead, an endpoint's method in its chip, and its name), and the tabs plugins give rows of the shape's kind (`RowDetails`: the kind's
// own, "Endpoint", its card's fields; Neighbors' Connections), never the shape's tabs and no status lines, so no Issues tab. A kind
// no plugin gives row tabs keeps the shape's panel.

/// A row of a shape, as a row tab's content is given it: the shape as it is, the row as its kind names it (`PartedShape.parts`), and
/// the editor, for its services.
@MainActor
public struct DetailRow {
    public let editor: CanvasEditor
    public let record: AnyShapeRecord
    public let part: PartName
    /// Whether the shape can't change (`editor.isReadOnly`): its row tabs show it, but none of them edits it.
    public let isReadOnly: Bool

    /// The shape's id.
    public var shape: ShapeID { record.id }
    /// The row, by its shape and its id.
    public var address: PartAddress { PartAddress(record.id, part: part.id) }

    /// A service, read-only.
    public func service<S: EditorService>(_ type: S.Type) -> S? { editor.service(S.self) }
}

/// One plugin's section in a row's tab, for the rows of the kinds its target reaches. Only the sugar makes one.
@MainActor
public struct RowDetailContribution {
    let tab: DetailTabID
    let id: String
    let title: String?
    /// Which rows it's for (an endpoint, not the path prefix over it): all, by default.
    let when: @MainActor (PartName) -> Bool
    let content: @MainActor (DetailRow) -> AnyView
}

/// The sections of a row's tabs (`rowDetails`), by the kinds whose rows they're for: keyed, so two plugins giving one tab the same
/// section for a kind conflict. A kind with any is a kind whose selected row is the panel's subject.
public enum RowDetails {}

extension RowDetails: KeyedExtensionPoint {
    public typealias Contribution = RowDetailContribution
    public static var owner: PluginID { .detailPanel }
    /// Sections on other kinds' rows say which: the kinds that have parts, a capability, or a property.
    public static var scope: PointScope { .scoped }

    public static func uniqueKeys(of contribution: RowDetailContribution, for target: ShapeTarget) -> [AnyHashable] {
        [DetailSectionKey(target: target, tab: contribution.tab, section: RowDetailContribution.sectionPrefix + contribution.id)]
    }

    /// Two tabs with one title would show as two identical tabs, a shape's and a row's alike.
    public static func check(_ registry: Registry) throws(RegistryError) {
        try DetailTabID.checkTabs(in: registry, point: "\(Self.self)")
    }

    /// "RowDetails in Connections → every shape with parts".
    public static func summary(of contribution: RowDetailContribution, for target: ShapeTarget) -> String {
        "\(Self.self) in \(contribution.tab.reported)" + (target == .any ? "" : " → \(target)")
    }
}

extension RowDetailContribution {
    /// A row's section's key is its own, apart from the shape's sections of one tab: what the panel remembers it folded by.
    static let sectionPrefix = "row:"
}

extension ShapeRegistrar {
    /// A section of a tab this kind's rows show when one is the panel's subject (one shape selected and one of its rows, as an item or
    /// the one its editing is on): the row's own details ("Endpoint": what its card holds), in plugin order within the tab.
    ///
    /// `when` says which rows have it (an API's endpoints, not its path prefixes): all, by default.
    ///
    ///     api.rowDetails(in: EndpointTab.self, id: "endpoint") { row in EndpointDetails(row: row) }
    public mutating func rowDetails<Tab: DetailTab, Content: View>(in tab: Tab.Type, id: String, title: String? = nil,
                                                                  when: @escaping @MainActor (PartName) -> Bool = { _ in true },
                                                                  @ViewBuilder _ content: @escaping @MainActor (DetailRow) -> Content) {
        contribute(RowDetailContribution(tab: DetailTabID(Tab.self), id: id, title: title, when: when, content: { AnyView(content($0)) }),
                   to: RowDetails.self)
    }
}

extension ScopedRegistrar {
    /// A section of a tab the rows of every kind the scope reaches show (`ShapeRegistrar.rowDetails`): what a feature shows of a row
    /// of a shape it doesn't define (Neighbors' Connections, on the kinds with parts).
    public mutating func rowDetails<Tab: DetailTab, Content: View>(in tab: Tab.Type, id: String, title: String? = nil,
                                                                  when: @escaping @MainActor (PartName) -> Bool = { _ in true },
                                                                  @ViewBuilder _ content: @escaping @MainActor (DetailRow) -> Content) {
        contribute(RowDetailContribution(tab: DetailTabID(Tab.self), id: id, title: title, when: when, content: { AnyView(content($0)) }),
                   to: RowDetails.self)
    }
}

extension ErasedSection {
    /// A row's section: shown always, its content made for the row of the record it's handed.
    init(row contribution: RowDetailContribution, part: PartName, isReadOnly: Bool) {
        tab = contribution.tab
        id = RowDetailContribution.sectionPrefix + contribution.id
        title = contribution.title
        isShown = { _ in true }
        let make = contribution.content
        content = { record, editor in make(DetailRow(editor: editor, record: record, part: part, isReadOnly: isReadOnly)) }
        isEnabledWhileReadOnly = true
        isShownWhile = nil
        isCollapsedUntilOpened = false
    }
}

extension CanvasEditor {
    /// The row the panel shows as its subject, when there is one: one shape selected, of a kind plugins give row tabs
    /// (`RowDetails`), with exactly one of its rows selected as an item (Selection's `selectedItems`), else, while it's edited, the
    /// row its editing has the keys on (`editingPart`). Nil otherwise: the panel shows the shape.
    public var detailRow: PartAddress? {
        guard selectedShapeIDs.count == 1, let id = selection, let record = document[id],
              !registry.contributions(to: RowDetails.self, reaching: record.kind).isEmpty else { return nil }
        if let items = selectedItems, items.shape == id, items.ids.count == 1, let part = items.ids[0].base as? PartID {
            return PartAddress(id, part: part)
        }
        if editingShapeID == id, let part = editingPart { return PartAddress(id, part: part) }
        return nil
    }
}

extension DetailPanelState {
    /// What the panel shows for a row (`editor.detailRow`): its header (its lead and name, `PartName`), and the tabs of the sections
    /// plugins give the rows of its shape's kind (`RowDetails`), each where its order puts it; no status lines. Nil for a row its
    /// shape doesn't list, or a kind with no row tabs.
    public func rowLayout(for record: AnyShapeRecord, part id: PartID) -> DetailLayout? {
        guard let part = editor.registry.parts(of: record)?.first(where: { $0.id == id }) else { return nil }
        let ordered = editor.registry.contributions(to: RowDetails.self, reaching: record.kind).filter { $0.value.when(part) }
        guard !ordered.isEmpty else { return nil }
        let isReadOnly = editor.isReadOnly(record.id)
        let sections = ordered.map { contribution in
            ResolvedSection(key: DetailSectionKey(target: contribution.target, tab: contribution.value.tab,
                                                  section: RowDetailContribution.sectionPrefix + contribution.value.id),
                            section: ErasedSection(row: contribution.value, part: part, isReadOnly: isReadOnly))
        }
        var firstSeen: [DetailTabID] = []
        for tab in sections.map(\.key.tab) where !firstSeen.contains(tab) { firstSeen.append(tab) }
        let tabs = OrderRule.arranged(firstSeen) { ($0.anchor, $0.order) }
        let label = editor.registry.label(of: record.kind)
        return DetailLayout(resolvedHeader: ResolvedHeader(DetailRowHeader(part)), kindName: part.kindWord, kindSymbol: label.systemImage, tabs: tabs,
                            sectionsByTab: Dictionary(grouping: sections, by: \.key.tab), statusesByTab: [:])
    }

    /// The key a row's chosen tab is kept under: its shape's kind's, apart from the shape's own, so choosing a row's Connections
    /// doesn't turn the shape's panel to it, nor the shape's tab a row's.
    static func rowKind(of kind: ShapeKind) -> ShapeKind { ShapeKind(rawValue: kind.rawValue + "#row") }
}

/// A row's header: its lead (a method in its chip, else its lead's symbol, else its shape's kind's) and its name, the chip's word left
/// out of the name it heads ("POST" and "/orders/{id}/refunds"); a row that doesn't stand alone says its kind word under it ("Column").
public struct DetailRowHeader: View, Equatable {
    public let part: PartName
    @Environment(\.detailKindSymbol) private var kindSymbol
    @Environment(\.paneTitleRow) private var row

    public init(_ part: PartName) { self.part = part }

    /// The name as the header shows it: after the chip's word, when the lead is a chip.
    public var title: String {
        if case .chip(let word, _) = part.lead, part.name.hasPrefix(word + " ") { return String(part.name.dropFirst(word.count + 1)) }
        return part.name
    }

    /// The line under the name: the kind word of a row read with its shape, none for one that stands alone.
    public var subtitle: String? { part.standsAlone ? nil : part.kindWord }

    public var body: some View {
        HStack(spacing: DetailStyle.pairSpacing) {
            switch part.lead {
            case .chip(let word, let fill):
                Text(word)
                    .font(DetailStyle.rowChipFont)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DetailStyle.rowChipPadding)
                    .frame(height: DetailStyle.rowChipHeight)
                    .background(RoundedRectangle(cornerRadius: DetailStyle.rowChipRadius).fill(Color(nsColor: NSColor(fill))))
                    .allowsHitTesting(false)
            case .symbol(let symbol):
                leadSymbol(symbol)
            case .none:
                if let kindSymbol { leadSymbol(kindSymbol) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(titleType.font).lineLimit(1).truncationMode(.middle).allowsHitTesting(false)
                if let subtitle {
                    Text(subtitle).font(row == nil ? DetailStyle.caption : DetailStyle.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([part.name, part.kindWord].joined(separator: ", "))
    }

    private func leadSymbol(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(DetailStyle.headerSymbol)
            .foregroundStyle(.secondary)
            .frame(width: DetailStyle.headerSymbolWidth)
            .allowsHitTesting(false)
    }

    private var titleType: DetailHeaderTitleType {
        guard row != nil else { return .header }
        return subtitle == nil ? .row : .rowOverSubtitle
    }

    nonisolated public static func == (a: Self, b: Self) -> Bool { a.part == b.part }
}

/// A row's panel (`DetailPanelState.rowLayout`): its header, its tabs and the chosen one's sections, as a shape's panel lays them out.
/// Made again for each row (`.id`), so a row's tab never shows another's; skipped while its shape's record, the row and whether it can
/// change are as they were.
struct RowPanel: View, Equatable {
    let state: DetailPanelState
    let editor: CanvasEditor
    let record: AnyShapeRecord
    let part: PartID
    let isReadOnly: Bool
    let contentChanged: @MainActor () -> Void
    let place: WindowBox

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.record == b.record && a.part == b.part && a.isReadOnly == b.isReadOnly }
    }

    var body: some View {
        #if DEBUG
        let _ = (state.panelsDrawn += 1)
        #endif
        if let layout = state.rowLayout(for: record, part: part) {
            let key = DetailPanelState.rowKind(of: record.kind)
            let current = state.currentTab(in: layout, for: key)
            let sections = current.map { layout.resolved(in: $0) } ?? []
            VStack(spacing: 0) {
                HeaderView(editor: editor, kindName: layout.kindName, kindSymbol: layout.kindSymbol, content: layout.resolvedHeader.view)
                if let current {
                    if layout.tabs.count > 1 {
                        TabStrip(tabs: layout.tabs, alert: { _ in nil }, selection: current) { state.choose($0, for: key) }
                            .onMoveCommand { direction in
                                switch direction {
                                case .left: state.stepTab(by: -1)
                                case .right: state.stepTab(by: 1)
                                default: break
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityAddTraits(.isTabBar)
                    }
                    Divider()
                    ScrollView {
                        TabContent(state: state, editor: editor, record: record, isReadOnly: isReadOnly, lines: [], sections: sections)
                            .equatable()
                    }
                    .background(ContentReader(box: place))
                }
                Spacer(minLength: 0)
            }
            .onChange(of: current) { contentChanged() }
        }
    }
}
