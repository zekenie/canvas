import AppKit
import Canvas
import Observation
import Selection

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
    /// Only tabs with at least one section shown for this shape, or a status line, each where its
    /// `order` puts it among them, counted from where it first appears (the kind's own contributions
    /// in plugin order, then every-box ones, then status lines').
    public let tabs: [DetailTabID]
    let sectionsByTab: [DetailTabID: [ResolvedSection]]
    let statusesByTab: [DetailTabID: [DetailStatus]]

    /// The header when it's a `DetailHeader` (the kind's own, or the kind's label a kind without
    /// one gets, `registry.label(of:)`), as shown: without a symbol of its own, with its kind's. Nil for a header of
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

    /// Of the tab's shown sections, those of the shape the stand-in shows (a mirror's original), which come after the
    /// stand-in's own.
    public func sectionsShownThrough(in tab: DetailTabID) -> [DetailSectionKey] { resolved(in: tab).filter(\.onShown).map(\.key) }

    func resolved(in tab: DetailTabID) -> [ResolvedSection] { sectionsByTab[tab] ?? [] }

    /// The tab's status lines (`DetailStatuses`), shown above its sections: the kind's
    /// contributions, then every kind's, each in plugin order.
    public func statuses(in tab: DetailTabID) -> [DetailStatus] { statusesByTab[tab] ?? [] }

    /// The worst tone of the tab's status lines when it's a warning or an error, whose symbol the
    /// tab strip shows before the tab's title, so a tab of problems looks like one from any tab;
    /// nil otherwise.
    public func alert(in tab: DetailTabID) -> DetailStatus.Tone? {
        statuses(in: tab).map(\.tone).max().flatMap { $0 >= .warning ? $0 : nil }
    }
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
    /// The section is the shape shown through the selected stand-in's, not the stand-in's own: it binds that shape.
    var onShown = false

    /// What a list of sections is keyed by: a stand-in and the shape it shows may both have a section under one key.
    struct ID: Hashable {
        let key: DetailSectionKey
        let onShown: Bool
    }
    var id: ID { ID(key: key, onShown: onShown) }
}

/// What the panel of a stand-in that shows another shape reads of that shape (`CanvasEditor.shown(through:)`): its record,
/// status lines, the sections `shownWhile` hides and whether it can change, read once on every commit, as the stand-in's
/// own are, so the panel draws again for the original's commits wherever it is and for no other.
struct ShownThrough: Equatable {
    let record: AnyShapeRecord
    let statuses: [ShapeStatuses.TabLines]
    let hidden: Set<DetailSectionKey>
    let isReadOnly: Bool
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
        /// Those shown only while a service says so (`shownWhile`): the only ones asked on every
        /// commit.
        let shownWhile: [ResolvedSection]
    }

    @ObservationIgnored private unowned let editor: CanvasEditor
    @ObservationIgnored private var candidates: [ShapeKind: Candidates] = [:]
    private var chosenTabs: [ShapeKind: DetailTabID] = [:]
    /// What the person collapsed or opened, by key; a section they haven't touched is open, unless it's
    /// collapsed until opened (`startsCollapsed`).
    private var folds: [DetailSectionKey: Bool] = [:]
    /// The sections that are collapsed until opened (`collapsedUntilOpened()`), as each kind's are gathered.
    @ObservationIgnored private var startsCollapsed: Set<DetailSectionKey> = []
    /// The shown panel's number being typed, if any (`DetailPanelView` sets it).
    @ObservationIgnored weak var drafts: DraftTracker?
    #if DEBUG
    /// How often a shape's panel has been drawn (debug builds only), so tests can hold a commit to
    /// drawing it again only when what it shows changes.
    @ObservationIgnored public var panelsDrawn = 0
    #endif

    init(editor: CanvasEditor) { self.editor = editor }

    public func layout(for record: AnyShapeRecord) -> DetailLayout {
        layout(for: record, statuses: statuses(of: record).tabs, hidden: hiddenSections(of: record))
    }

    /// What the panel shows for the shape `id`: its own layout, and, when it's a stand-in that shows another shape
    /// (`editor.shown(through:)`: a reference expanded into a mirror), then that shape's tabs, their sections bound to it.
    /// Nil for no such shape.
    public func panelLayout(for id: ShapeID) -> DetailLayout? {
        guard let record = editor.document[id] else { return nil }
        return layout(for: record, statuses: statuses(of: record).tabs, hidden: hiddenSections(of: record), through: shown(through: id))
    }

    /// What the stand-in shows, read for its panel; nil for a shape that shows none now.
    func shown(through id: ShapeID) -> ShownThrough? {
        guard let (shownID, _) = editor.shown(through: id), let record = editor.shape(inFile: shownID) else { return nil }
        return ShownThrough(record: record, statuses: statuses(of: record).tabs, hidden: hiddenSections(of: record),
                            isReadOnly: editor.isReadOnly(inFile: shownID))
    }

    /// With the shape's status lines for tabs, and the sections `shownWhile` hides, read already; and, for a stand-in, what
    /// it shows: the stand-in's own tabs that shape's panel doesn't have (a reference's Reference), then that shape's tabs,
    /// so a tab both have (Connections, every shape's) is the shape's alone, said once.
    func layout(for record: AnyShapeRecord, statuses: [ShapeStatuses.TabLines], hidden: Set<DetailSectionKey>,
                through: ShownThrough? = nil) -> DetailLayout {
        let all = candidates[record.kind] ?? resolve(record.kind)
        let shown = all.sections.filter { $0.section.isShown(record) && !hidden.contains($0.key) }
        let tabs = arranged(shown, statuses)
        var sectionsByTab = Dictionary(grouping: shown, by: \.key.tab)
        var statusesByTab = Dictionary(uniqueKeysWithValues: statuses.map { ($0.tab, $0.lines) })
        var allTabs = tabs
        if let through {
            let original = candidates[through.record.kind] ?? resolve(through.record.kind)
            let more = original.sections.filter { $0.section.isShown(through.record) && !through.hidden.contains($0.key) }
                .map { var section = $0; section.onShown = true; return section }
            let theirs = arranged(more, through.statuses)
            allTabs = tabs.filter { !theirs.contains($0) } + theirs
            for tab in theirs {
                sectionsByTab[tab] = nil
                statusesByTab[tab] = nil
            }
            for (tab, sections) in Dictionary(grouping: more, by: \.key.tab) { sectionsByTab[tab] = sections }
            for lines in through.statuses { statusesByTab[lines.tab, default: []] += lines.lines }
        }
        // The kind's header, else the kind's label (`registry.label(of:)`).
        let label = editor.registry.label(of: record.kind)
        let header = all.headers.lazy.compactMap { [editor] in $0(record, editor) }.first ?? ResolvedHeader(DetailHeader(label.name))
        return DetailLayout(resolvedHeader: header, kindName: label.name, kindSymbol: label.systemImage, tabs: allTabs,
                            sectionsByTab: sectionsByTab, statusesByTab: statusesByTab)
    }

    /// The tabs sections and status lines fill, each where its `order` puts it, counted from where it first appears.
    private func arranged(_ sections: [ResolvedSection], _ statuses: [ShapeStatuses.TabLines]) -> [DetailTabID] {
        var firstSeen: [DetailTabID] = []
        for tab in sections.map(\.key.tab) + statuses.map(\.tab) where !firstSeen.contains(tab) { firstSeen.append(tab) }
        return OrderRule.arranged(firstSeen) { ($0.anchor, $0.order) }
    }

    /// The kind's own contributions, then those whose scope reaches it, each in plugin order. Once per
    /// kind: the registry is frozen.
    private func resolve(_ kind: ShapeKind) -> Candidates {
        let ordered = editor.registry.contributions(to: ShapeDetails.self, reaching: kind)
        let sections = ordered.flatMap { contribution in
            contribution.value.sections.map {
                ResolvedSection(key: DetailSectionKey(target: contribution.target, tab: $0.tab, section: $0.id), section: $0)
            }
        }
        let resolved = Candidates(headers: ordered.compactMap(\.value.header), sections: sections,
                                  shownWhile: sections.filter { $0.section.isShownWhile != nil })
        for section in sections where section.section.isCollapsedUntilOpened { startsCollapsed.insert(section.key) }
        candidates[kind] = resolved
        return resolved
    }

    /// The sections of the shape's kind that `shownWhile` hides just now. Asked on every commit (a
    /// section's `shownWhile` reads services, not the record alone), and of only the sections
    /// that have one: none for most kinds.
    func hiddenSections(of record: AnyShapeRecord) -> Set<DetailSectionKey> {
        let all = candidates[record.kind] ?? resolve(record.kind)
        guard !all.shownWhile.isEmpty else { return [] }
        let context = DetailContext(editor: editor)
        var hidden: Set<DetailSectionKey> = []
        for resolved in all.shownWhile where resolved.section.isShownWhile?(record, context) == false {
            hidden.insert(resolved.key)
        }
        return hidden
    }

    /// The header shown when several shapes are selected: "N Shapes", with each kind's name once,
    /// in selection order ("Note, Arrow"), and stacked squares. A kind's name is its label
    /// (`registry.label(of:)`).
    public func selectionSummary(of records: [AnyShapeRecord]) -> DetailHeader {
        var names: [String] = []
        for record in records {
            let name = editor.registry.label(of: record.kind).name
            if !names.contains(name) { names.append(name) }
        }
        return DetailHeader("\(records.count) Shapes", subtitle: names.joined(separator: ", "), systemImage: "square.on.square")
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

    /// The tab chosen for the kind (`choose`, a click on the strip, Next Inspector Tab), nil while none has been:
    /// what a plugin that chooses a tab for a while (a walk through issues) keeps to give back.
    public func chosenTab(for kind: ShapeKind) -> DetailTabID? { chosenTabs[kind] }

    /// Lets go of the choice for the kind: its panel opens on the first tab again, as before any choice.
    public func forgetChoice(for kind: ShapeKind) { chosenTabs[kind] = nil }

    /// The tabs the panel shows for the one shape selected, and the one chosen among them; nil with
    /// no one shape selected or fewer than two tabs, where there is nothing to step between, and
    /// while a takeover (Find), which has no tab strip, shows in their place.
    private func shownTabs() -> (kind: ShapeKind, tabs: [DetailTabID], index: Int)? {
        guard editor.selectedShapeIDs.count == 1, let id = editor.selection, let record = editor.document[id],
              editor.registry.activeDetailTakeover(in: editor) == nil else { return nil }
        guard let layout = panelLayout(for: id) else { return nil }
        guard layout.tabs.count > 1, let current = currentTab(in: layout, for: record.kind),
              let index = layout.tabs.firstIndex(of: current) else { return nil }
        return (record.kind, layout.tabs, index)
    }

    /// Whether `stepTab(by:)` has tabs to step between.
    public var canStepTab: Bool { shownTabs() != nil }

    /// View › Next Inspector Tab (+1) and Previous Inspector Tab (-1): the tab `delta` after the one
    /// shown among those the shape's panel has, round the ends. The keyboard then goes to the new
    /// tab's first control (`focusesFirstControl`), as a click on a tab does not: the keys that
    /// switched it are the ones that go on into it. False when there is nothing to step.
    @discardableResult
    public func stepTab(by delta: Int) -> Bool {
        guard let shown = shownTabs() else { return false }
        let count = shown.tabs.count
        choose(shown.tabs[((shown.index + delta) % count + count) % count], for: shown.kind)
        focusesFirstControl?()
        return true
    }

    /// Gives the keyboard to the first control of the tab shown, once the panel has drawn it: the
    /// panel sets it as it appears (it knows its window).
    @ObservationIgnored var focusesFirstControl: (@MainActor () -> Void)?

    /// Gives the keyboard to the first control of the shape's panel as a takeover that was over it closes (a list the keyboard
    /// was in, closed by Return), once the panel has drawn it: the controls there are now are left alone, so the band keeps
    /// to its own. A panel with no control the keys reach gives the canvas the keyboard. The panel sets how, as it appears.
    public func focusContent() { focusesContent?() }

    @ObservationIgnored var focusesContent: (@MainActor () -> Void)?

    /// Whether a takeover listed before the plugin's own is active, so it shows in place of the plugin's (the first that is active
    /// shows, in plugin order): for a plugin whose takeover may be covered by another's (the issue walk's list under Find's panel)
    /// to turn its own way in off while it is. For a plugin with no takeover of its own, whether any is. Reads what each
    /// `isActive` reads, so a view that asks follows it.
    public func hasTakeover(over plugin: PluginID) -> Bool {
        for takeover in editor.registry.contributions(to: DetailTakeovers.self) {
            if takeover.pluginID == plugin { return false }
            if takeover.value.isActive(editor) { return true }
        }
        return false
    }

    /// Gives the canvas the keyboard, as the panel's `onExit` does on Escape: for a plugin whose view in the panel remembers the
    /// canvas had it (the issue walk's list, closed). The panel sets how, as it appears.
    public func exitToCanvas() { exitsToCanvas?() }

    @ObservationIgnored var exitsToCanvas: (@MainActor () -> Void)?

    /// Writes a number being typed in the panel, as Return in its field does: for a plugin that is about to take the panel
    /// over (a takeover turning active removes the shape's panel as it stands, and its draft with it).
    public func commitDraft() { drafts?.commit() }

    /// The view of the panel that takes the keyboard when the window gives the inspector the keyboard
    /// (the host slot's `keyboardEntry`): the header's field, else its first control; nil when the
    /// panel has neither. The panel sets it as it appears (it knows its window).
    @ObservationIgnored public var keyboardEntry: (@MainActor () -> NSView?)?

    /// Where in the panel the keyboard is, if it is in it: the band over the panel, a takeover
    /// (Find's panel, a list over the shape's), or the rest (the shape's panel, the overview). Nil with
    /// the keyboard elsewhere, the canvas's or another window's. Read when asked, from the window's first
    /// responder; the panel sets how, as it appears.
    public var keyboardPlace: KeyboardPlace? { keyboardPlaceReader?() ?? nil }

    /// The panel's answer to `keyboardPlace`, set as it appears (it knows its window).
    @ObservationIgnored var keyboardPlaceReader: (@MainActor () -> KeyboardPlace?)?

    /// Gives the keyboard to the band's first control, if a band is showing and has one the keys can
    /// reach (a button is one only with Keyboard navigation on). Whether it did: Escape goes on to the
    /// canvas when it didn't. The panel sets how, as it appears.
    @discardableResult
    public func focusBand() -> Bool { focusesBand?() ?? false }

    @ObservationIgnored var focusesBand: (@MainActor () -> Bool)?

    /// Remembered by key: an every-box section collapses for every kind, a kind's own for that kind. One
    /// collapsed until opened is collapsed until the person opens it, for every kind its key reaches.
    public func isCollapsed(_ key: DetailSectionKey) -> Bool { folds[key] ?? startsCollapsed.contains(key) }

    public func setCollapsed(_ key: DetailSectionKey, _ isCollapsed: Bool) {
        folds[key] = isCollapsed
    }
}

/// Where in the panel the keyboard is (`DetailPanelState.keyboardPlace`).
public enum KeyboardPlace: Sendable {
    /// In the band over the panel (`DetailBands`).
    case band
    /// In a takeover (`DetailTakeovers`), the band aside.
    case takeover
    /// In the shape's panel or the overview.
    case content
}

extension DetailPanelState: EditorService {
    /// A number being typed for a shape of the board left is written to it while it's still there
    /// to write to.
    public func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) { drafts?.commit() }
}

extension CanvasEditor {
    /// The panel's state; nil without DetailPanelPlugin.
    public var detailPanel: DetailPanelState? { service(DetailPanelState.self) }
}
