import Canvas
import SwiftUI

/// The table of contents, as a plugin: an outline of the board's shapes, one row each, shown in the
/// detail panel when it has no one shape to show. Each kind says how its shapes appear
/// (data-canvas's TOC card providers): the row, which shapes are listed, and which shape a row
/// nests under. The rows are a Mac source list's, so rows from different plugins line up. Selecting
/// on the canvas lists just the selected shapes; selecting a row selects its shape and brings it
/// into view. The core never learns what a table of contents is.
extension PluginID {
    public static let tableOfContents: PluginID = "table-of-contents"
}

// MARK: The extension point

/// How a kind's shapes appear in the table of contents. At most one contribution per kind: two
/// are `RegistryError.conflict` at startup. A kind with none is listed with the label and symbol
/// of the tool that places it.
public enum ContentsRows {}

extension ContentsRows: KeyedExtensionPoint {
    public typealias Contribution = ContentsContribution
    public static var owner: PluginID { .tableOfContents }
    public static func uniqueKeys(of _: ContentsContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// What `ContentsRows` stores for a kind: its row (nil for the tool's label and symbol), and which
/// shapes are listed and under what. Only the sugar below makes one.
@MainActor
public struct ContentsContribution {
    let isListed: @MainActor (AnyShapeRecord) -> Bool
    let parent: (@MainActor (AnyShapeRecord) -> ShapeID?)?
    let row: (@MainActor (AnyShapeRecord) -> ResolvedRow)?
}

/// What a shape's row is called, when a plugin other than the one that draws the row says: a
/// horizontal that names shapes (Titles) names them here, and the kind keeps its row. At most one
/// per kind, plus one for every kind: two are `RegistryError.conflict` at startup. A name that
/// isn't blank takes the place of a `ContentsLabel` row's title (the kind's own row, or the tool's
/// label a kind without one gets), which keeps its symbol, color and badge; nil or blank leaves the
/// row as it is. A row that isn't a plain `ContentsLabel` is its kind's own view, and stays so.
public enum ContentsTitles {}

extension ContentsTitles: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (AnyShapeRecord) -> String?
    public static var owner: PluginID { .tableOfContents }
    public static func uniqueKeys(of _: Contribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// A row as a kind drew it, and, when it's a plain `ContentsLabel`, that label, for tests to read.
@MainActor
struct ResolvedRow {
    let view: AnyView
    let label: ContentsLabel?

    init<Row: View>(_ row: Row) {
        view = AnyView(row)
        label = row as? ContentsLabel
    }
}

extension ContentsContribution {
    init<P: ShapeProps, Row: View>(_: P.Type, isListed: @escaping @MainActor (ShapeRecord<P>) -> Bool,
                                   parent: (@MainActor (ShapeRecord<P>) -> ShapeID?)?, row: @escaping (ShapeRecord<P>) -> Row) {
        self.init(P.self, isListed: isListed, parent: parent,
                  row: { record in record.typed(as: P.self).map { ResolvedRow(row($0)) } ?? ResolvedRow(EmptyView()) })
    }

    /// Without `row`, the tool's label and symbol.
    init<P: ShapeProps>(_: P.Type, isListed: @escaping @MainActor (ShapeRecord<P>) -> Bool, parent: (@MainActor (ShapeRecord<P>) -> ShapeID?)?,
                        row: (@MainActor (AnyShapeRecord) -> ResolvedRow)? = nil) {
        self.isListed = { $0.typed(as: P.self).map(isListed) ?? false }
        if let parent {
            self.parent = { $0.typed(as: P.self).flatMap(parent) }
        } else {
            self.parent = nil
        }
        self.row = row
    }
}

// MARK: Sugar (what verticals, horizontals and bridges write)

extension ShapeRegistrar {
    /// This kind's row in the table of contents, a view that reads only this shape:
    ///
    ///     note.contentsRow { note in
    ///         ContentsLabel(note.props.text, placeholder: "Empty Note", badge: ...)
    ///     }
    ///
    /// `when` lists only some shapes; the rest have no row. `nestedUnder` names the shape this one's
    /// row goes under (an arrow under the shape it starts from), which holds only while that shape
    /// is listed too: otherwise the row is at the top, so a selection of just this shape still
    /// shows it.
    public mutating func contentsRow<Row: View>(
        when isListed: @escaping @MainActor (ShapeRecord<Definition.Props>) -> Bool = { _ in true },
        nestedUnder parent: (@MainActor (ShapeRecord<Definition.Props>) -> ShapeID?)? = nil,
        @ViewBuilder _ row: @escaping (ShapeRecord<Definition.Props>) -> Row
    ) {
        contribute(ContentsContribution(Definition.Props.self, isListed: isListed, parent: parent, row: row), to: ContentsRows.self)
    }

    /// This kind's shapes with the row a kind without one gets (its tool's label and symbol),
    /// listed where `when` says and nested where `nestedUnder` says, as above:
    ///
    ///     arrow.contentsRow(nestedUnder: { $0.props.start.binding?.shapeID })
    public mutating func contentsRow(
        when isListed: @escaping @MainActor (ShapeRecord<Definition.Props>) -> Bool = { _ in true },
        nestedUnder parent: (@MainActor (ShapeRecord<Definition.Props>) -> ShapeID?)? = nil
    ) {
        contribute(ContentsContribution(Definition.Props.self, isListed: isListed, parent: parent), to: ContentsRows.self)
    }

    /// What this kind's rows are called, whoever draws them: a name that isn't blank replaces the
    /// row's title, and keeps its symbol, color and badge; nil keeps the title. A horizontal that
    /// names shapes calls this from its own opt-in (Titles' `title` does), so the kind's row and its
    /// name can come from different plugins.
    public mutating func contentsTitle(_ make: @escaping @MainActor (ShapeRecord<Definition.Props>) -> String?) {
        contribute({ $0.typed(as: Definition.Props.self).flatMap(make) }, to: ContentsTitles.self)
    }
}

extension PluginRegistrar {
    /// The row for a kind another plugin registers (bridges). Typed as the kind's own.
    public mutating func contentsRow<P: ShapeProps, Row: View>(
        _: P.Type,
        when isListed: @escaping @MainActor (ShapeRecord<P>) -> Bool = { _ in true },
        nestedUnder parent: (@MainActor (ShapeRecord<P>) -> ShapeID?)? = nil,
        @ViewBuilder _ row: @escaping (ShapeRecord<P>) -> Row
    ) {
        contribute(ContentsContribution(P.self, isListed: isListed, parent: parent, row: row), to: ContentsRows.self, for: .kind(P.kind))
    }

    /// What the rows of a kind another plugin registers are called (bridges), as above.
    public mutating func contentsTitle<P: ShapeProps>(_: P.Type, _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        contribute({ $0.typed(as: P.self).flatMap(make) }, to: ContentsTitles.self, for: .kind(P.kind))
    }
}

// MARK: The row

/// The row most kinds want, as a Mac source list shows one: a symbol, a title on one line, and a count
/// or short note at the trailing end. A blank title shows `placeholder`, dimmed. Without a symbol
/// of its own, the row shows the one of the tool that places its kind.
public struct ContentsLabel: View {
    public let title: String
    public let placeholder: String?
    public let systemImage: String?
    /// The symbol's color. Nil, the list's (the accent color).
    public let color: Color?
    /// Trailing, in the secondary color: "2/5", "Sep 30". Keep it to a few characters.
    public let badge: String?

    @Environment(\.contentsSymbol) private var kindSymbol

    public init(_ title: String, placeholder: String? = nil, systemImage: String? = nil, color: Color? = nil, badge: String? = nil) {
        self.title = title
        self.placeholder = placeholder
        self.systemImage = systemImage
        self.color = color
        self.badge = badge
    }

    /// What the row reads: the title on one line (each run of whitespace, newlines included, folds
    /// into one space), or the placeholder when that leaves nothing.
    public var text: String {
        let folded = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.isEmpty ? placeholder ?? "" : folded
    }

    public var isPlaceholder: Bool { title.allSatisfy(\.isWhitespace) && placeholder != nil }

    /// The same label, called `title` (`ContentsTitles`).
    func retitled(_ title: String) -> ContentsLabel {
        ContentsLabel(title, placeholder: placeholder, systemImage: systemImage, color: color, badge: badge)
    }

    public var body: some View {
        HStack(spacing: ContentsStyle.badgeSpacing) {
            Label {
                Text(text).foregroundStyle(isPlaceholder ? .secondary : .primary)
            } icon: {
                if let color {
                    Image(systemName: systemImage ?? kindSymbol).foregroundStyle(color)
                } else {
                    Image(systemName: systemImage ?? kindSymbol)
                }
            }
            Spacer(minLength: 0)
            if let badge {
                Text(badge).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .lineLimit(1)
    }
}

/// The symbol of the tool that places the row's kind, which a `ContentsLabel` without its own shows.
struct ContentsSymbolKey: EnvironmentKey {
    static let defaultValue = "square.dashed"
}

extension EnvironmentValues {
    var contentsSymbol: String {
        get { self[ContentsSymbolKey.self] }
        set { self[ContentsSymbolKey.self] = newValue }
    }
}

// MARK: The plugin

/// The table of contents' state. Contributes no rows of its own: a kind nobody describes is listed
/// by its tool's label and symbol.
public struct TableOfContentsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .tableOfContents }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ContentsState(editor: $0) }
    }
}

@MainActor
enum ContentsStyle {
    static let badgeSpacing: CGFloat = 6
    /// A hovered row's tint, in the selection highlight's place: inset from the row's sides, with
    /// its corners.
    static let hoverOpacity: CGFloat = 0.14
    static let highlightInset: CGFloat = 10
    static let highlightRadius: CGFloat = 8
    /// Selecting rows brings their shapes into view as data-canvas's TOC does (its zoom config, and
    /// tldraw's zoomToBounds): 100 points of margin in all, no closer than 120%, over 200 ms.
    static let zoomInset: CGFloat = 100
    static let maxZoom: CGFloat = 1.2
    static let zoomDuration: Duration = .milliseconds(200)
}
