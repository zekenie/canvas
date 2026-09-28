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
///     public enum ChecklistTab {}
///     extension ChecklistTab: DetailTab {
///         public static var title: String { "Checklist" }
///         public static var order: Int { 50 }
///     }
///
/// Two tab types may not share a title: the registry refuses the plugin list (`RegistryError.invalid`).
public protocol DetailTab {
    static var title: String { get }
    /// Tabs sort by this, then by first appearance. The bands: 0 for a kind's own tabs (the
    /// default), 50 for a feature tab a horizontal adds to the kinds that opt into it, 100 for
    /// Style and 200 for Arrange, so the shared tabs trail, as in Keynote, and 300 for a tab of the
    /// shape's state that comes and goes with it (Issues), last, so the others keep their order.
    /// (The strip shares its width among the tabs, so a tab that comes narrows the rest.)
    static var order: Int { get }
}

extension DetailTab {
    public static var order: Int { 0 }
}

/// Appearance: color, what the shape shows. Share it rather than making a near-duplicate.
public enum StyleTab {}
extension StyleTab: DetailTab {
    public static var title: String { "Style" }
    public static var order: Int { 100 }
}

/// Position and size. The panel fills it for every box shape.
public enum ArrangeTab {}
extension ArrangeTab: DetailTab {
    public static var title: String { "Arrange" }
    public static var order: Int { 200 }
}

/// A tab as the layout reports it. Equal when the tab types are.
public struct DetailTabID: Hashable, Sendable, CustomStringConvertible {
    let type: ObjectIdentifier
    public let title: String
    let order: Int
    /// Module-qualified (`TaskCards.TaskTab`): stable across launches, for persisting later.
    public let name: String

    init<T: DetailTab>(_: T.Type) {
        type = ObjectIdentifier(T.self)
        title = T.title
        order = T.order
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
    /// An SF Symbol. Nil: the symbol of the tool that places this kind.
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

/// One section of a tab: an optional bold header (collapsible, with an optional control at its
/// trailing end), then rows. `Value` is what it edits: a kind's props, or a box's frame.
///
/// The content closure gets a `ShapeBinding`. Take it as `$task`: `task.notes` is the value,
/// `$task.notes` a `Binding` that writes that one field in its own transaction.
/// (The closure types are deliberately unannotated: annotated `@MainActor`, Swift 6.3 compiles a
/// `$`-parameter body as nonisolated, and every view initializer in it fails.)
@MainActor
public struct DetailSection<Value> {
    let tab: DetailTabID
    let id: String
    let title: String?
    let isShown: @MainActor (Value) -> Bool
    let content: @MainActor (ShapeBinding<Value>) -> AnyView
    let accessory: (@MainActor (ShapeBinding<Value>) -> AnyView)?
    private(set) var isEnabledWhileReadOnly = false

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
        accessory = nil
    }

    /// With one small control in the header row, which acts on the whole section (Checklists'
    /// menu). A switch for one row goes in that row, beside what it governs.
    public init<Tab: DetailTab, Content: View, Accessory: View>(
        _ title: String, in tab: Tab.Type, id: String? = nil,
        when isShown: @escaping @MainActor (Value) -> Bool = { _ in true },
        @ViewBuilder content: @escaping (ShapeBinding<Value>) -> Content,
        @ViewBuilder accessory: @escaping (ShapeBinding<Value>) -> Accessory
    ) {
        self.tab = DetailTabID(Tab.self)
        self.id = id ?? title
        self.title = title
        self.isShown = isShown
        self.content = { AnyView(content($0)) }
        self.accessory = { AnyView(accessory($0)) }
    }

    /// The section, its controls working on a read-only shape (a locked one) too, where the panel
    /// disables every other section's: for controls that change nothing of the shape, as Boards'
    /// Open, which goes into it. What they write is refused there all the same.
    ///
    ///     DetailSection(in: BoardTab.self) { _ in
    ///         DetailCommandButton("Open", command: .openSelection)
    ///     }
    ///     .enabledWhileReadOnly()
    public func enabledWhileReadOnly() -> Self {
        var section = self
        section.isEnabledWhileReadOnly = true
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
/// what collapse is remembered by. Prints as "task-card Style/Color" (or "* Arrange/Size").
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
    let accessory: (@MainActor (AnyShapeRecord, CanvasEditor) -> AnyView)?
    let isEnabledWhileReadOnly: Bool

    init<Value>(_ section: DetailSection<Value>, value: @escaping @MainActor (AnyShapeRecord) -> Value?,
                binding: @escaping @MainActor (AnyShapeRecord, CanvasEditor) -> ShapeBinding<Value>?) {
        tab = section.tab
        id = section.id
        title = section.title
        isEnabledWhileReadOnly = section.isEnabledWhileReadOnly
        let shown = section.isShown, content = section.content
        isShown = { value($0).map(shown) ?? false }
        // Its writes are undo steps named for it; one without a title's, for the kind.
        let stepName = section.title.map { "Change \($0)" }
        let binding = { @MainActor (record: AnyShapeRecord, editor: CanvasEditor) in binding(record, editor)?.named(stepName) }
        self.content = { record, editor in binding(record, editor).map(content) ?? AnyView(EmptyView()) }
        if let accessory = section.accessory {
            self.accessory = { record, editor in binding(record, editor).map(accessory) ?? AnyView(EmptyView()) }
        } else {
            accessory = nil
        }
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

    public static func uniqueKeys(of contribution: DetailContribution, for target: ShapeTarget) -> [AnyHashable] {
        contribution.sections.map { DetailSectionKey(target: target, tab: $0.tab, section: $0.id) }
            + (contribution.header == nil ? [] : [HeaderKey(target: target)])
    }

    /// Two tabs with one title would show as two identical tabs.
    public static func check(_ registry: Registry) throws(RegistryError) {
        try DetailTabID.checkTitles(in: registry, point: "\(Self.self)")
    }
}

extension DetailTabID {
    /// Refuses two tab types with one title, whether sections or status lines name them. Both of
    /// the panel's points run it, since either may name a tab the other doesn't.
    @MainActor static func checkTitles(in registry: Registry, point: String) throws(RegistryError) {
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
    }
}

/// Lines of a shape's state, not its settings: pinned at the foot of the panel, on every tab, or in
/// a tab of their own, which shows only while the shape has lines there (ValidationDetails lists a
/// shape's issues in an Issues tab). A list: the kind's contributions, then every kind's, each in
/// plugin order. Re-read on every document change, so keep them cheap (read a cached service, like
/// validation's engine).
public enum DetailStatuses {}

extension DetailStatuses: ExtensionPoint {
    public typealias Contribution = DetailStatusContribution
    public static var owner: PluginID { .detailPanel }

    /// Two tabs with one title would show as two identical tabs.
    public static func check(_ registry: Registry) throws(RegistryError) {
        try DetailTabID.checkTitles(in: registry, point: "\(Self.self)")
    }

    /// Lines for a tab name it: "DetailStatuses in Issues".
    public static func summary(of contribution: DetailStatusContribution, for target: ShapeTarget) -> String {
        "\(Self.self)" + (contribution.tab.map { " in \($0.title)" } ?? "") + (target == .any ? "" : " → \(target)")
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

// MARK: Sugar (what verticals, horizontals and bridges write)

extension ShapeRegistrar {
    /// This kind's sections, in one call (one contribution, one report line). A horizontal's opt-in
    /// sugar calls this too, so opting into its feature brings its tab.
    public mutating func details(@DetailSectionsBuilder<Definition.Props> _ sections: () -> [DetailSection<Definition.Props>]) {
        contribute(DetailContribution(Definition.Props.self, sections: sections()), to: ShapeDetails.self)
    }

    /// This kind's header and sections, in one call:
    ///
    ///     task.details(header: { $task in DetailHeader("Task", subtitle: $task.shape.summary) }) {
    ///         DetailSection(in: TaskTab.self) { $task in LabeledContent("Notes") { TextField("Notes", text: $task.notes) } }
    ///         DetailSection("Color", in: StyleTab.self) { $task in ... }
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
    /// horizontal's opt-in sugar contributes for the property it opts the kind into
    /// (`note.checklist()`). Each write changes the value, in one transaction.
    public mutating func details<P: ShapeProperty>(of _: P.Type, @DetailSectionsBuilder<P.Value> _ sections: () -> [DetailSection<P.Value>]) {
        contribute(DetailContribution(property: P.self, sections: sections()), to: ShapeDetails.self)
    }
}

extension PluginRegistrar {
    /// Sections over an added property's value, on every shape that has one, whatever its kind.
    public mutating func details<P: ShapeProperty>(of _: P.Type, @DetailSectionsBuilder<P.Value> _ sections: () -> [DetailSection<P.Value>]) {
        contribute(DetailContribution(property: P.self, sections: sections()), to: ShapeDetails.self, for: .any)
    }

    /// Sections for a kind another plugin registers (bridges). Typed as the kind's own.
    public mutating func details<P: ShapeProps>(_: P.Type, @DetailSectionsBuilder<P> _ sections: () -> [DetailSection<P>]) {
        contribute(DetailContribution(P.self, sections: sections()), to: ShapeDetails.self, for: .kind(P.kind))
    }

    /// Header and sections for a kind another plugin registers (bridges), as `details(header:)` on
    /// a kind's own registrar.
    public mutating func details<P: ShapeProps, Header: View>(
        _: P.Type, @ViewBuilder header: @escaping (ShapeBinding<P>) -> Header,
        @DetailSectionsBuilder<P> _ sections: () -> [DetailSection<P>]
    ) {
        contribute(DetailContribution(P.self, header: DetailContribution.makeHeader(P.self, header), sections: sections()), to: ShapeDetails.self, for: .kind(P.kind))
    }

    /// Sections for every shape with a frame, editing the frame. Shapes without one (arrows)
    /// don't get them.
    public mutating func detailsForEveryBox(@DetailSectionsBuilder<CGRect> _ sections: () -> [DetailSection<CGRect>]) {
        let erased = sections().map { ErasedSection($0, value: \.box, binding: ShapeBinding<CGRect>.box) }
        contribute(DetailContribution(header: nil, sections: erased), to: ShapeDetails.self, for: .any)
    }

    /// Footer lines for every shape: return [] when there's nothing to say.
    public mutating func detailStatusForEveryShape(_ make: @escaping @MainActor (AnyShapeRecord, DetailContext) -> [DetailStatus]) {
        contribute(DetailStatusContribution(make), to: DetailStatuses.self, for: .any)
    }

    /// Lines in a tab of their own for every shape, the tab showing only while a shape has some:
    /// return [] when there's nothing to say.
    ///
    ///     registrar.detailStatusForEveryShape(in: IssuesTab.self) { shape, context in ... }
    public mutating func detailStatusForEveryShape<Tab: DetailTab>(
        in tab: Tab.Type, _ make: @escaping @MainActor (AnyShapeRecord, DetailContext) -> [DetailStatus]
    ) {
        contribute(DetailStatusContribution(in: tab, make), to: DetailStatuses.self, for: .any)
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
