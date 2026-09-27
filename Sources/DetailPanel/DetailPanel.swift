import Canvas
import CoreGraphics
import SwiftUI

extension PluginID {
    public static let detailPanel: PluginID = "detail-panel"
}

// MARK: Tabs

/// A tab of the panel. The type is the tab: every section that names it lands in it, so sharing a
/// tab means importing the module that declares it, and a typo doesn't compile. Any plugin may
/// declare one; it shows for a shape when a section that applies to the shape names it.
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
    /// Style and 200 for Arrange, so the shared tabs trail, as in Keynote.
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

/// The panel's top line: what is selected. A value, not a view, so every header looks alike.
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

/// A line pinned at the panel's foot, on every tab: the shape's state, not a setting.
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
/// The content closure gets a `ShapeBinding`. Take it as `$task`: `task.title` is the value,
/// `$task.title` a `Binding` that writes that one field in its own transaction.
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
    let header: (@MainActor (AnyShapeRecord) -> DetailHeader?)?
    let sections: [ErasedSection]
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

    init<Value>(_ section: DetailSection<Value>, value: @escaping @MainActor (AnyShapeRecord) -> Value?,
                binding: @escaping @MainActor (AnyShapeRecord, CanvasEditor) -> ShapeBinding<Value>?) {
        tab = section.tab
        id = section.id
        title = section.title
        let shown = section.isShown, content = section.content
        isShown = { value($0).map(shown) ?? false }
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
        var first: [String: (tab: DetailTabID, plugin: PluginID)] = [:]
        for contribution in registry.contributions(to: ShapeDetails.self) {
            for tab in contribution.value.sections.map(\.tab) {
                guard let seen = first[tab.title] else {
                    first[tab.title] = (tab, contribution.pluginID)
                    continue
                }
                guard seen.tab == tab else {
                    throw .invalid(point: "\(Self.self)", reason: "\(seen.tab.name) (from \(seen.plugin)) and \(tab.name) "
                                   + "(from \(contribution.pluginID)) are both tabs titled \"\(tab.title)\"; share one, or retitle one")
                }
            }
        }
    }
}

/// Lines pinned at the foot of the panel, on every tab. A list: the kind's contributions, then
/// every kind's, each in plugin order. Re-read on every document change, so keep them cheap (read
/// a cached service, like validation's engine).
public enum DetailStatuses: ExtensionPoint {
    public typealias Contribution = @MainActor (AnyShapeRecord, DetailContext) -> [DetailStatus]
    public static var owner: PluginID { .detailPanel }
}

/// What a status contributor may read besides the shape: services, read-only.
@MainActor
public struct DetailContext {
    let editor: CanvasEditor
    public func service<S: EditorService>(_ type: S.Type) -> S? { editor.service(S.self) }
}

// MARK: Sugar (what verticals, horizontals and bridges write)

extension ShapeRegistrar {
    /// This kind's panel, in one call (one contribution, one report line):
    ///
    ///     task.details(header: { DetailHeader($0.props.title) }) {
    ///         DetailSection(in: TaskTab.self) { $task in LabeledContent("Title") { TextField("Title", text: $task.title) } }
    ///         DetailSection("Color", in: StyleTab.self) { $task in ... }
    ///     }
    ///
    /// A header alone is `details(header: ...) {}`. A horizontal's opt-in sugar calls this too, so
    /// opting into its feature brings its tab.
    public mutating func details(
        header: (@MainActor (ShapeRecord<Definition.Props>) -> DetailHeader)? = nil,
        @DetailSectionsBuilder<Definition.Props> _ sections: () -> [DetailSection<Definition.Props>]
    ) {
        contribute(DetailContribution(Definition.Props.self, header: header, sections: sections()), to: ShapeDetails.self)
    }
}

extension PluginRegistrar {
    /// Header and sections for a kind another plugin registers (bridges). Typed as the kind's own.
    public mutating func details<P: ShapeProps>(
        _: P.Type, header: (@MainActor (ShapeRecord<P>) -> DetailHeader)? = nil,
        @DetailSectionsBuilder<P> _ sections: () -> [DetailSection<P>]
    ) {
        contribute(DetailContribution(P.self, header: header, sections: sections()), to: ShapeDetails.self, for: .kind(P.kind))
    }

    /// Sections for every shape with a frame, editing the frame. Shapes without one (arrows)
    /// don't get them.
    public mutating func detailsForEveryBox(@DetailSectionsBuilder<CGRect> _ sections: () -> [DetailSection<CGRect>]) {
        let erased = sections().map { ErasedSection($0, value: \.box, binding: ShapeBinding<CGRect>.box) }
        contribute(DetailContribution(header: nil, sections: erased), to: ShapeDetails.self, for: .any)
    }

    /// Footer lines for every shape: return [] when there's nothing to say.
    public mutating func detailStatusForEveryShape(_ make: @escaping @MainActor (AnyShapeRecord, DetailContext) -> [DetailStatus]) {
        contribute(make, to: DetailStatuses.self, for: .any)
    }
}

extension DetailContribution {
    init<P: ShapeProps>(_: P.Type, header: (@MainActor (ShapeRecord<P>) -> DetailHeader)?, sections: [DetailSection<P>]) {
        if let header {
            self.header = { $0.typed(as: P.self).map(header) }
        } else {
            self.header = nil
        }
        self.sections = sections.map { ErasedSection($0, value: { $0.typed(as: P.self)?.props }, binding: ShapeBinding<P>.props) }
    }
}
