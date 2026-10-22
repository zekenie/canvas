import Canvas
import CoreGraphics
import SwiftUI

extension PluginID {
    public static let detailPanel: PluginID = "detail-panel"
}

// MARK: Tabs

/// A tab of the panel. The type is the tab: every section that names it lands in it, so sharing a
/// tab means importing the module that declares it, and a typo doesn't compile. Any plugin may
/// declare one; it shows for a shape when a section that applies to the shape names it, or when the
/// shape has status lines for it (`DetailStatuses`).
///
///     public enum TypeSchemaTab {}
///     extension TypeSchemaTab: DetailTab {
///         public static var title: String { "Schema" }
///         public static var order: Order<Self> { .after(NeighborsTab.self) }
///     }
///
/// Two tab types may not share a title: the registry refuses the plugin list (`RegistryError.invalid`).
public protocol DetailTab: SendableMetatype {
    static var title: String { get }
    /// Where it goes among a shape's tabs (`Order`). By default where it first appears: a kind's own
    /// contributions first, then the rest in plugin order. A kind's own tabs are first (a subboard's
    /// Description), so a feature's tab its opt-in brings, which says nothing, goes after them; Style
    /// is last, as a shared tab trails in Keynote; a tab of the shape's state that comes and goes with
    /// it (Issues) is after Style, so the others keep their places; a type's Schema is after
    /// Connections, so a type's panel opens on what's connected to it. (The strip shares its width
    /// among the tabs, so a tab that comes narrows the rest.)
    static var order: Order<Self> { get }
}

extension DetailTab {
    public static var order: Order<Self> { .natural }

    /// How another tab names this one, to be placed beside it.
    static var orderAnchor: OrderAnchor { OrderAnchor(Self.self, name: title) { order.rule } }
}

extension Order where Subject: DetailTab {
    /// Right before `tab`.
    public static func before<Tab: DetailTab>(_: Tab.Type) -> Self { Self(.before(Tab.orderAnchor)) }
    /// Right after `tab`.
    public static func after<Tab: DetailTab>(_: Tab.Type) -> Self { Self(.after(Tab.orderAnchor)) }
}

/// Appearance: color, what the shape shows. Share it rather than making a near-duplicate.
public enum StyleTab {}
extension StyleTab: DetailTab {
    public static var title: String { "Style" }
    public static var order: Order<Self> { .last }
}

/// A tab as the layout reports it. Equal when the tab types are.
public struct DetailTabID: Hashable, Sendable, CustomStringConvertible {
    let type: ObjectIdentifier
    public let title: String
    /// Where it goes among a shape's tabs, and how another tab names it.
    let order: OrderRule
    let anchor: OrderAnchor
    /// Module-qualified (`Schemas.SchemaTab`): stable across launches, for persisting later.
    public let name: String

    init<T: DetailTab>(_: T.Type) {
        type = ObjectIdentifier(T.self)
        title = T.title
        order = T.order.rule
        anchor = T.orderAnchor
        name = String(reflecting: T.self)
    }

    public static func of<T: DetailTab>(_ tab: T.Type) -> DetailTabID { DetailTabID(tab) }
    public static func == (a: Self, b: Self) -> Bool { a.type == b.type }
    public func hash(into hasher: inout Hasher) { hasher.combine(type) }
    public var description: String { title }
}

// MARK: Values contributors hand the panel

/// The panel's top line: what is selected, as the panel lays it out (`DetailHeaderLabel`): a symbol,
/// a title and a subtitle. The header most kinds give, and the one a kind without its own gets. A
/// header can be another view (Titles' `TitleHeader` renames the shape in place); built from
/// `DetailHeaderLabel`, it looks like this one.
public struct DetailHeader: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    /// An SF Symbol. Nil: this kind's (`registry.label(of:)`).
    public var systemImage: String?

    public init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }
}

/// A line of the shape's state, not a setting: pinned at the panel's foot, on every tab, or in a tab
/// of its own (`DetailStatuses`).
public struct DetailStatus: Hashable, Sendable {
    public enum Tone: Int, Comparable, Sendable {
        case neutral, info, warning, error
        public static func < (a: Tone, b: Tone) -> Bool { a.rawValue < b.rawValue }
    }

    public var text: String
    public var tone: Tone

    public init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }
}

// MARK: Sections

/// One section of a tab: an optional bold header (collapsible), then rows. `Value` is what it
/// edits: a kind's props, or a box's frame.
///
/// The content closure gets a `ShapeBinding`. Take it as `$card`: `card.schema` is the value,
/// `$card.schema` a `Binding` that writes that one field in its own transaction.
/// (The closure types are deliberately unannotated: annotated `@MainActor`, Swift 6.3 compiles a
/// `$`-parameter body as nonisolated, and every view initializer in it fails.)
@MainActor
public struct DetailSection<Value> {
    let tab: DetailTabID
    let id: String
    let title: String?
    let isShown: @MainActor (Value) -> Bool
    let content: @MainActor (ShapeBinding<Value>) -> AnyView
    private(set) var isEnabledWhileReadOnly = false
    private(set) var isShownWhile: (@MainActor (AnyShapeRecord, DetailContext) -> Bool)?
    private(set) var stepNoun: String?
    private(set) var isCollapsedUntilOpened = false

    /// `title == nil` is a headerless block that never collapses (the top of a tab). `id` defaults
    /// to the title, or "main"; it keys conflicts and remembered collapse. `when` hides the section
    /// (and a tab it leaves empty) for some values; keep it cheap, it runs on every render.
    public init<Tab: DetailTab, Content: View>(
        _ title: String? = nil, in tab: Tab.Type, id: String? = nil,
        when isShown: @escaping @MainActor (Value) -> Bool = { _ in true },
        @ViewBuilder content: @escaping (ShapeBinding<Value>) -> Content
    ) {
        self.tab = DetailTabID(Tab.self)
        self.id = id ?? title ?? "main"
        self.title = title
        self.isShown = isShown
        self.content = { AnyView(content($0)) }
    }

    /// The section, its controls working on a read-only shape (a locked one) too, where the panel
    /// disables every other section's: for controls that change nothing of the shape, as the
    /// Connections tab's rows, which go to what's connected. What they write is refused there all
    /// the same.
    ///
    ///     DetailSection(in: NeighborsTab.self, id: "neighbors") { shape in
    ///         NeighborListView(subject: shape.shapeID, list: shape.service(NeighborList.self))
    ///     }
    ///     .enabledWhileReadOnly()
    public func enabledWhileReadOnly() -> Self {
        var section = self
        section.isEnabledWhileReadOnly = true
        return section
    }

    /// The section, collapsed until the person opens it: for what most people never change, as Finder's
    /// Get Info keeps Sharing & Permissions folded (Types' Advanced, under a shape's Fields). Only a
    /// titled section collapses. Opened, or collapsed again, it stays as the person left it for the
    /// window's session, as any section's collapse is remembered (`DetailPanelState`, by key).
    ///
    ///     DetailSection("Advanced", in: TypesTab.self, id: "advanced") { shape in … }
    ///         .collapsedUntilOpened()
    public func collapsedUntilOpened() -> Self {
        var section = self
        section.isCollapsedUntilOpened = true
        return section
    }

    /// The section, its writes' undo steps named for `noun` ("Change Color") where it has no title to
    /// name them: a headerless section that is one row, whose label says what it is.
    ///
    ///     DetailSection(in: StyleTab.self, id: "Color") { $x in LabeledContent("Color") { … } }
    ///         .named("Color")
    public func named(_ noun: String) -> Self {
        var section = self
        section.stepNoun = noun
        return section
    }

    /// The section, shown only while `isShown` says so (and `when` too, which reads only the
    /// value): of the shape and what the editor's services keep about it, for a section of the
    /// shape's state that comes and goes (whether other shapes link to it, say). A tab shows only
    /// while it has a section shown (or status lines). It's asked on every commit, as status lines
    /// are, whatever the commit changed (a drag of another shape), so it must cost O(1): read a
    /// service's cached state. A view in the section that shows more of that state observes it
    /// itself: the section is built again only when its shape changes.
    ///
    ///     DetailSection(in: LinksTab.self) { $x in … }
    ///         .shownWhile { shape, context in context.service(Links.self)?.isLinked(shape.id) == true }
    public func shownWhile(_ isShown: @escaping @MainActor (AnyShapeRecord, DetailContext) -> Bool) -> Self {
        var section = self
        section.isShownWhile = isShown
        return section
    }
}

@resultBuilder
public enum DetailSectionsBuilder<Value> {
    public static func buildExpression(_ section: DetailSection<Value>) -> [DetailSection<Value>] { [section] }
    public static func buildBlock(_ parts: [DetailSection<Value>]...) -> [DetailSection<Value>] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [DetailSection<Value>]?) -> [DetailSection<Value>] { part ?? [] }
}

/// Where a section is: which shapes, which tab, which section. The key a contribution claims, and
/// what collapse is remembered by. Prints as "sticky-note Schema/JSON" (or "* Arrange/Size").
public struct DetailSectionKey: Hashable, Sendable, CustomStringConvertible {
    public let target: ShapeTarget
    public let tab: DetailTabID
    public let section: String
    public var description: String { "\(target) \(tab.title)/\(section)" }
}

struct HeaderKey: Hashable, CustomStringConvertible {
    let target: ShapeTarget
    var description: String { "header for \(target)" }
}

/// What `ShapeDetails` stores: one plugin's header and sections for one target, erased. Only the
/// sugar below makes one.
@MainActor
public struct DetailContribution {
    let header: (@MainActor (AnyShapeRecord, CanvasEditor) -> ResolvedHeader?)?
    let sections: [ErasedSection]
}

/// A header as a kind built it: the view, and the value it was, for `DetailLayout.header(as:)`.
@MainActor
struct ResolvedHeader {
    let view: AnyView
    let value: Any

    init<Header: View>(_ header: Header) {
        view = AnyView(header)
        value = header
    }
}

/// A section over any record: hidden, and empty, for a record it can't bind.
@MainActor
struct ErasedSection {
    let tab: DetailTabID
    let id: String
    let title: String?
    let isShown: @MainActor (AnyShapeRecord) -> Bool
    let content: @MainActor (AnyShapeRecord, CanvasEditor) -> AnyView
    let isEnabledWhileReadOnly: Bool
    /// `shownWhile`'s, asked apart from `isShown`: on every commit, beside the status lines.
    let isShownWhile: (@MainActor (AnyShapeRecord, DetailContext) -> Bool)?
    /// `collapsedUntilOpened()`'s: collapsed while the person hasn't opened it.
    let isCollapsedUntilOpened: Bool

    init<Value>(_ section: DetailSection<Value>, value: @escaping @MainActor (AnyShapeRecord) -> Value?,
                binding: @escaping @MainActor (AnyShapeRecord, CanvasEditor) -> ShapeBinding<Value>?) {
        tab = section.tab
        id = section.id
        title = section.title
        isEnabledWhileReadOnly = section.isEnabledWhileReadOnly
        isShownWhile = section.isShownWhile
        isCollapsedUntilOpened = section.isCollapsedUntilOpened && section.title != nil
        let shown = section.isShown, content = section.content
        isShown = { value($0).map(shown) ?? false }
        // Its writes are undo steps named for it (its title, or what it says names them); one with
        // neither, for the kind.
        let stepName = (section.stepNoun ?? section.title).map { "Change \($0)" }
        let binding = { @MainActor (record: AnyShapeRecord, editor: CanvasEditor) in binding(record, editor)?.named(stepName) }
        self.content = { record, editor in binding(record, editor).map(content) ?? AnyView(EmptyView()) }
    }
}

// MARK: Extension points

/// The panel's header and sections. Keyed: each section claims (target, tab, id), and a header
/// claims its target, so two plugins adding "Color" to a kind's Style tab, or two headers for one
/// kind, are `RegistryError.conflict` at startup. A kind's own and an every-box section may share
/// an id; both show, the kind's first. Two tab types with one title are `RegistryError.invalid`.
public enum ShapeDetails {}

extension ShapeDetails: KeyedExtensionPoint {
    public typealias Contribution = DetailContribution
    public static var owner: PluginID { .detailPanel }
    /// Sections on other kinds' shapes say which: the kinds that hold a property, have a capability, or every shape.
    public static var scope: PointScope { .scoped }

    public static func uniqueKeys(of contribution: DetailContribution, for target: ShapeTarget) -> [AnyHashable] {
        contribution.sections.map { DetailSectionKey(target: target, tab: $0.tab, section: $0.id) }
            + (contribution.header == nil ? [] : [HeaderKey(target: target)])
    }

    /// Two tabs with one title would show as two identical tabs.
    public static func check(_ registry: Registry) throws(RegistryError) {
        try DetailTabID.checkTabs(in: registry, point: "\(Self.self)")
    }

    /// Sections name their tabs, each with its order if it says one: "ShapeDetails in Schema after
    /// Connections → every shape holding schema".
    public static func summary(of contribution: DetailContribution, for target: ShapeTarget) -> String {
        var tabs: [DetailTabID] = []
        for section in contribution.sections where !tabs.contains(section.tab) { tabs.append(section.tab) }
        return "\(Self.self)" + (tabs.isEmpty ? "" : " in " + tabs.map(\.reported).joined(separator: ", "))
            + (target == .any ? "" : " → \(target)")
    }
}

extension DetailTabID {
    /// As the registry's report names it: its title, and its order if it says one ("Style last").
    var reported: String { order == .natural ? title : "\(title) \(order)" }

    /// Refuses two tab types with one title, whether sections or status lines name them, and tabs
    /// placed beside each other in a circle. Both of the panel's points run it, since either may
    /// name a tab the other doesn't.
    @MainActor static func checkTabs(in registry: Registry, point: String) throws(RegistryError) {
        let sectionTabs = registry.contributions(to: ShapeDetails.self).flatMap { contribution in
            contribution.value.sections.map { (tab: $0.tab, plugin: contribution.pluginID) }
        }
        let statusTabs = registry.contributions(to: DetailStatuses.self).compactMap { contribution in
            contribution.value.tab.map { (tab: $0, plugin: contribution.pluginID) }
        }
        var first: [String: (tab: DetailTabID, plugin: PluginID)] = [:]
        for (tab, plugin) in sectionTabs + statusTabs {
            guard let seen = first[tab.title] else {
                first[tab.title] = (tab, plugin)
                continue
            }
            guard seen.tab == tab else {
                throw .invalid(point: point, reason: "\(seen.tab.name) (from \(seen.plugin)) and \(tab.name) "
                               + "(from \(plugin)) are both tabs titled \"\(tab.title)\"; share one, or retitle one")
            }
        }
        if let cycle = OrderRule.cycle(from: (sectionTabs + statusTabs).map(\.tab.anchor)) {
            throw .invalid(point: point, reason: "tabs placed beside each other in a circle: \(cycle)")
        }
    }
}

/// Lines of a shape's state, not its settings: pinned at the foot of the panel, on every tab, or in
/// a tab of their own, which shows only while the shape has lines there (Validation lists a
/// shape's issues in an Issues tab). A list: the kind's contributions, then every kind's, each in
/// plugin order. Re-read on every document change, so keep them cheap (read a cached service, like
/// validation's engine).
public enum DetailStatuses {}

extension DetailStatuses: ExtensionPoint {
    public typealias Contribution = DetailStatusContribution
    public static var owner: PluginID { .detailPanel }
    /// Lines on other kinds' shapes say which: the kinds that hold a property, have a capability, or every shape.
    public static var scope: PointScope { .scoped }

    /// Two tabs with one title would show as two identical tabs.
    public static func check(_ registry: Registry) throws(RegistryError) {
        try DetailTabID.checkTabs(in: registry, point: "\(Self.self)")
    }

    /// Lines for a tab name it, with its order if it says one: "DetailStatuses in Issues after Style".
    public static func summary(of contribution: DetailStatusContribution, for target: ShapeTarget) -> String {
        "\(Self.self)" + (contribution.tab.map { " in \($0.reported)" } ?? "") + (target == .any ? "" : " → \(target)")
    }
}

/// What `DetailStatuses` holds: where a contribution's lines go, and how to make a shape's.
@MainActor
public struct DetailStatusContribution {
    /// Nil for the footer.
    let tab: DetailTabID?
    let make: @MainActor (AnyShapeRecord, DetailContext) -> [DetailStatus]

    /// Lines for the foot of the panel: return [] when there's nothing to say.
    public init(_ make: @escaping @MainActor (AnyShapeRecord, DetailContext) -> [DetailStatus]) {
        tab = nil
        self.make = make
    }

    /// Lines for `tab`, which shows while a shape has some there, above the tab's sections if it has
    /// any: return [] when there's nothing to say.
    public init<Tab: DetailTab>(in _: Tab.Type, _ make: @escaping @MainActor (AnyShapeRecord, DetailContext) -> [DetailStatus]) {
        tab = DetailTabID(Tab.self)
        self.make = make
    }
}

/// What a status contributor may read besides the shape: services, read-only.
@MainActor
public struct DetailContext {
    let editor: CanvasEditor
    public func service<S: EditorService>(_ type: S.Type) -> S? { editor.service(S.self) }
}

// MARK: Sugar (what verticals and horizontals write)

extension ShapeRegistrar {
    /// This kind's sections, in one call (one contribution, one report line). A horizontal's opt-in
    /// sugar calls this too, so opting into its feature brings its tab.
    public mutating func details(@DetailSectionsBuilder<Definition.Props> _ sections: () -> [DetailSection<Definition.Props>]) {
        contribute(DetailContribution(Definition.Props.self, sections: sections()), to: ShapeDetails.self)
    }

    /// This kind's header and sections, in one call:
    ///
    ///     note.details(header: { $note in TitleHeader($note) }) {
    ///         DetailSection("Text", in: NoteTab.self) { $note in NoteText(note: $note) }
    ///     }
    ///
    /// The header is a view made from the shape's binding, as a section's content is: a
    /// `DetailHeader`, or a header that edits the shape, built on `DetailHeaderLabel` (Titles'
    /// `TitleHeader($note)` renames it). A header alone is `details(header: ...) {}`.
    public mutating func details<Header: View>(
        @ViewBuilder header: @escaping (ShapeBinding<Definition.Props>) -> Header,
        @DetailSectionsBuilder<Definition.Props> _ sections: () -> [DetailSection<Definition.Props>]
    ) {
        contribute(DetailContribution(Definition.Props.self, header: DetailContribution.makeHeader(Definition.Props.self, header), sections: sections()),
                   to: ShapeDetails.self)
    }
}

extension ShapeRegistrar {
    /// Sections over an added property's value, on this kind's shapes that have one: what a
    /// horizontal's opt-in sugar contributes for the property it opts the kind into. Each write
    /// changes the value, in one transaction.
    public mutating func details<P: ShapeProperty>(of _: P.Type, @DetailSectionsBuilder<P.Value> _ sections: () -> [DetailSection<P.Value>]) {
        contribute(DetailContribution(property: P.self, sections: sections()), to: ShapeDetails.self)
    }
}

extension PluginRegistrar {
    /// Sections over an added property's value, on every shape that has one, whatever its kind: for the
    /// kinds that hold the property (the report's "every shape holding <key>").
    public mutating func details<P: ShapeProperty>(of _: P.Type, @DetailSectionsBuilder<P.Value> _ sections: () -> [DetailSection<P.Value>]) {
        contribute(DetailContribution(property: P.self, sections: sections()), to: ShapeDetails.self, for: .holding(P.key))
    }

    /// Sections for a kind another plugin registers. Typed as the kind's own.
    public mutating func details<P: ShapeProps>(_: P.Type, @DetailSectionsBuilder<P> _ sections: () -> [DetailSection<P>]) {
        contribute(DetailContribution(P.self, sections: sections()), to: ShapeDetails.self, for: .kind(P.kind))
    }

    /// Header and sections for a kind another plugin registers, as `details(header:)` on
    /// a kind's own registrar.
    public mutating func details<P: ShapeProps, Header: View>(
        _: P.Type, @ViewBuilder header: @escaping (ShapeBinding<P>) -> Header,
        @DetailSectionsBuilder<P> _ sections: () -> [DetailSection<P>]
    ) {
        contribute(DetailContribution(P.self, header: DetailContribution.makeHeader(P.self, header), sections: sections()), to: ShapeDetails.self, for: .kind(P.kind))
    }

    /// Sections for every shape with a frame, editing the frame: for the kinds whose shapes are boxes
    /// (`ShapeCapability.box`), so shapes without one (arrows) don't get them.
    public mutating func detailsForEveryBox(@DetailSectionsBuilder<CGRect> _ sections: () -> [DetailSection<CGRect>]) {
        let erased = sections().map { ErasedSection($0, value: \.box, binding: ShapeBinding<CGRect>.box) }
        contribute(DetailContribution(header: nil, sections: erased), to: ShapeDetails.self, for: .adopting(.box))
    }
}

extension ScopedRegistrar {
    /// Sections on the shapes of every kind the scope reaches, over the whole record: for what a feature
    /// shows about shapes it doesn't define (Colors' row on the kinds that hold a color), or, in
    /// `forEveryShape`, what every shape has (what it's connected to). A section that shows only in some
    /// state says so with `shownWhile`. Writes through the binding change the record, one step named for
    /// the section.
    ///
    ///     registrar.forShapes(holding: ColorProperty.self) { colorable in
    ///         colorable.details { DetailSection(in: StyleTab.self, id: "color") { $record in … } }
    ///     }
    public mutating func details(@DetailSectionsBuilder<AnyShapeRecord> _ sections: () -> [DetailSection<AnyShapeRecord>]) {
        let erased = sections().map {
            ErasedSection($0, value: { $0 }, binding: { record, editor in ShapeBinding<AnyShapeRecord>.record(of: record, in: editor) })
        }
        contribute(DetailContribution(header: nil, sections: erased), to: ShapeDetails.self)
    }

    /// Footer lines for the shapes of every kind the scope reaches: return [] when there's nothing to say.
    public mutating func detailStatus(_ make: @escaping @MainActor (AnyShapeRecord, DetailContext) -> [DetailStatus]) {
        contribute(DetailStatusContribution(make), to: DetailStatuses.self)
    }

    /// Lines in a tab of their own for the shapes of every kind the scope reaches, the tab showing only
    /// while a shape has some: return [] when there's nothing to say.
    ///
    ///     registrar.forEveryShape { every in every.detailStatus(in: IssuesTab.self) { shape, context in ... } }
    public mutating func detailStatus<Tab: DetailTab>(
        in tab: Tab.Type, _ make: @escaping @MainActor (AnyShapeRecord, DetailContext) -> [DetailStatus]
    ) {
        contribute(DetailStatusContribution(in: tab, make), to: DetailStatuses.self)
    }
}

extension DetailContribution {
    init<P: ShapeProperty>(property _: P.Type, sections: [DetailSection<P.Value>]) {
        self.init(header: nil, sections: sections.map {
            ErasedSection($0, value: { $0[P.self] }, binding: { ShapeBinding<P.Value>.property(P.self, of: $0, in: $1) })
        })
    }

    init<P: ShapeProps>(_: P.Type, header: (@MainActor (AnyShapeRecord, CanvasEditor) -> ResolvedHeader?)? = nil, sections: [DetailSection<P>]) {
        self.init(header: header, sections: sections.map { ErasedSection($0, value: { $0.typed(as: P.self)?.props }, binding: ShapeBinding<P>.props) })
    }

    /// A header made from the shape's binding, as a section's content is; none for a record it
    /// can't bind.
    static func makeHeader<P: ShapeProps, Header: View>(_: P.Type, _ make: @escaping (ShapeBinding<P>) -> Header)
        -> @MainActor (AnyShapeRecord, CanvasEditor) -> ResolvedHeader? {
        { record, editor in ShapeBinding<P>.props(of: record, in: editor).map { ResolvedHeader(make($0)) } }
    }
}
