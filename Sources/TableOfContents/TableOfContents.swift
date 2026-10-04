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
/// are `RegistryError.conflict` at startup. A kind with none is listed with its label and symbol
/// (`registry.label(of:)`), nested under the container its shape is in. A row reads only its
/// shape, unless it also names, with `affected`, the shapes each commit may change the rows of
/// without changing them: their rows are made again, and kept unless their labels changed. A row
/// says what its shape is, never where it is: a move keeps it.
public enum ContentsRows {}

extension ContentsRows: KeyedExtensionPoint {
    public typealias Contribution = ContentsContribution
    public static var owner: PluginID { .tableOfContents }
    public static func uniqueKeys(of _: ContentsContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// What `ContentsRows` stores for a kind: its row (nil for the kind's label and symbol), which
/// shapes are listed and under what, and, for a row read from more than its shape, which shapes'
/// rows a commit may change besides the shapes it changes. Only the sugar below makes one.
@MainActor
public struct ContentsContribution {
    let isListed: @MainActor (AnyShapeRecord) -> Bool
    let parent: (@MainActor (AnyShapeRecord) -> ShapeID?)?
    let row: (@MainActor (AnyShapeRecord, ContentsContext) -> ResolvedRow)?
    let affected: (@MainActor (ChangeSet, ContentsContext) -> Set<ShapeID>)?
}

/// What a shape's row is called, when a plugin other than the one that draws the row says: a
/// horizontal that names shapes (Titles) names them here, and the kind keeps its row. At most one
/// per kind, plus one for every kind: two are `RegistryError.conflict` at startup. A name that
/// isn't blank takes the place of a `ContentsLabel` row's title (the kind's own row, or the kind's
/// label a kind without one gets), which keeps its symbol, color and badge; nil or blank leaves the
/// row as it is. A row that isn't a plain `ContentsLabel` is its kind's own view, and stays so.
public enum ContentsTitles {}

extension ContentsTitles: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (AnyShapeRecord) -> String?
    public static var owner: PluginID { .tableOfContents }
    public static func uniqueKeys(of _: Contribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// Marks at the trailing end of a shape's row, from any plugin: a state worth seeing at a glance down
/// the list (Validation marks a shape with issues with a red or orange dot, Locking a locked
/// one with a lock). A list: the kind's contributions, then every kind's that apply to it, each in
/// plugin order, and a row shows every mark it gets. A
/// mark is part of the row, made with it, and made again with it when a commit changes the shape.
/// A mark read from other shapes (validation's rules may look at other shapes) also names, with
/// `affected`, the shapes a commit may change the marks of without changing them: their marks are
/// read again, and their rows kept unless the marks changed. So marks follow the document, and a
/// commit costs the rows it changes and the marks it may.
public enum ContentsMarks: ExtensionPoint {
    public typealias Contribution = ContentsMarkContribution
    public static var owner: PluginID { .tableOfContents }
}

/// What `ContentsMarks` stores: how to mark a shape's row, and, for a mark that reads more than the
/// shape, which shapes' marks a commit may change besides the shapes it changes.
@MainActor
public struct ContentsMarkContribution {
    let mark: @MainActor (AnyShapeRecord, ContentsContext) -> ContentsMark?
    let affected: (@MainActor (ChangeSet, ContentsContext) -> Set<ShapeID>)?
    /// Which kinds an every-shape mark is for, asked once per kind.
    let appliesTo: @MainActor (ContentsKind) -> Bool

    /// `mark` gives the shape's mark, nil for none. `affected`, given each commit's change set,
    /// names the shapes it doesn't change whose marks it may; leave it out for a mark that reads
    /// only its shape. `appliesTo` picks the kinds a mark for every shape goes on.
    public init(affected: (@MainActor (ChangeSet, ContentsContext) -> Set<ShapeID>)? = nil,
                where appliesTo: @escaping @MainActor (ContentsKind) -> Bool = { _ in true },
                _ mark: @escaping @MainActor (AnyShapeRecord, ContentsContext) -> ContentsMark?) {
        self.mark = mark
        self.affected = affected
        self.appliesTo = appliesTo
    }
}

/// A kind, as the `where` of a mark for every shape sees it (`contentsMarkForEveryShape(where:)`):
/// asked once per kind, so a mark goes only on the kinds that opted into what it marks.
@MainActor
public struct ContentsKind {
    public let kind: ShapeKind
    public let registry: Registry

    /// Whether this kind's shapes hold an added property: opted into it, however (Locking's lock
    /// goes on the kinds that can be locked, `$0.holds(LockedProperty.self)`).
    public func holds<P: ShapeProperty>(_: P.Type) -> Bool { registry.properties(for: kind).contains(P.key) }
}

/// A mark at a row's trailing end: a small dot in `color`, or, with `symbol`, that SF Symbol in it
/// (a lock). `help` says what it means, as its tooltip and to VoiceOver.
public struct ContentsMark: Hashable, Sendable {
    public var symbol: String?
    public var color: Color
    public var help: String

    public init(symbol: String? = nil, color: Color, help: String) {
        self.symbol = symbol
        self.color = color
        self.help = help
    }
}

/// What a mark contributor, or a row read from more than its shape, may read besides the shape:
/// services, read-only.
@MainActor
public struct ContentsContext {
    let editor: CanvasEditor
    public func service<S: EditorService>(_ type: S.Type) -> S? { editor.service(S.self) }
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
                  row: { record, _ in record.typed(as: P.self).map { ResolvedRow(row($0)) } ?? ResolvedRow(EmptyView()) })
    }

    /// A row read from more than its shape, with the shapes a commit may change the rows of.
    init<P: ShapeProps>(_: P.Type, isListed: @escaping @MainActor (ShapeRecord<P>) -> Bool, parent: (@MainActor (ShapeRecord<P>) -> ShapeID?)?,
                        affected: @escaping @MainActor (ChangeSet, ContentsContext) -> Set<ShapeID>,
                        row: @escaping @MainActor (ShapeRecord<P>, ContentsContext) -> ContentsLabel) {
        self.init(P.self, isListed: isListed, parent: parent,
                  row: { record, context in record.typed(as: P.self).map { ResolvedRow(row($0, context)) } ?? ResolvedRow(EmptyView()) },
                  affected: affected)
    }

    /// Without `row`, the kind's label and symbol (`registry.label(of:)`).
    init<P: ShapeProps>(_: P.Type, isListed: @escaping @MainActor (ShapeRecord<P>) -> Bool, parent: (@MainActor (ShapeRecord<P>) -> ShapeID?)?,
                        row: (@MainActor (AnyShapeRecord, ContentsContext) -> ResolvedRow)? = nil,
                        affected: (@MainActor (ChangeSet, ContentsContext) -> Set<ShapeID>)? = nil) {
        self.isListed = { $0.typed(as: P.self).map(isListed) ?? false }
        if let parent {
            self.parent = { $0.typed(as: P.self).flatMap(parent) }
        } else {
            self.parent = nil
        }
        self.row = row
        self.affected = affected
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
    /// row goes under (an arrow under the shape it starts from); a shape it names none for, as every
    /// shape of a kind without it, goes under the container it's in (a frame). Either holds only while
    /// that shape is listed too: otherwise the row is at the top, so a selection of just this shape
    /// still shows it. Both, and the row, say what the shape is, never where it is: a commit that
    /// only moves the shape keeps its row.
    public mutating func contentsRow<Row: View>(
        when isListed: @escaping @MainActor (ShapeRecord<Definition.Props>) -> Bool = { _ in true },
        nestedUnder parent: (@MainActor (ShapeRecord<Definition.Props>) -> ShapeID?)? = nil,
        @ViewBuilder _ row: @escaping (ShapeRecord<Definition.Props>) -> Row
    ) {
        contribute(ContentsContribution(Definition.Props.self, isListed: isListed, parent: parent, row: row), to: ContentsRows.self)
    }

    /// This kind's row, read from more than this shape: the builder gets what `ContentsContext`
    /// lends (the editor's services) besides the shape, and returns a `ContentsLabel`, so rows can be
    /// compared. `affected`, given each commit's change set, names the shapes the commit doesn't
    /// change whose rows it may. A ref's row that shows the name of the shape it refers to, with a
    /// service of its plugin's own that keeps which refs refer to each shape:
    ///
    ///     ref.contentsRow(affected: { changes, context in
    ///         context.service(RefIndex.self)?.refs(to: changes.shapeIDs) ?? []
    ///     }) { ref, context in
    ///         ContentsLabel("→ " + (context.service(RefIndex.self)?.name(of: ref.props.target) ?? "?"))
    ///     }
    ///
    /// Those rows are made again on the next read, and replaced (so redrawn) only if their labels
    /// changed; the shapes the commit changes get new rows, as always. `affected` runs on every
    /// commit, listed or not, so it must cost what the commit changed, never the board: a service
    /// that keeps who reads what answers it. Read before it hears of a commit, the table of contents
    /// makes every kept row of such a kind again, since only hearing of the commit says which it
    /// affects. `when` and `nestedUnder` read only the shape, as above. The row reads what other
    /// shapes are (their names, their state), never where they are: another board's outline
    /// (`ContentsState.outline(of:)`, where `affected` can't answer) makes such rows again after a
    /// commit that did more than move shapes, and not after a move.
    public mutating func contentsRow(
        when isListed: @escaping @MainActor (ShapeRecord<Definition.Props>) -> Bool = { _ in true },
        nestedUnder parent: (@MainActor (ShapeRecord<Definition.Props>) -> ShapeID?)? = nil,
        affected: @escaping @MainActor (ChangeSet, ContentsContext) -> Set<ShapeID>,
        _ row: @escaping @MainActor (ShapeRecord<Definition.Props>, ContentsContext) -> ContentsLabel
    ) {
        contribute(ContentsContribution(Definition.Props.self, isListed: isListed, parent: parent, affected: affected, row: row),
                   to: ContentsRows.self)
    }

    /// This kind's shapes with the row a kind without one gets (its label and symbol),
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

    /// The row, read from more than its shape, for a kind another plugin registers (bridges), as
    /// `ShapeRegistrar`'s `contentsRow(when:nestedUnder:affected:_:)`.
    public mutating func contentsRow<P: ShapeProps>(
        _: P.Type,
        when isListed: @escaping @MainActor (ShapeRecord<P>) -> Bool = { _ in true },
        nestedUnder parent: (@MainActor (ShapeRecord<P>) -> ShapeID?)? = nil,
        affected: @escaping @MainActor (ChangeSet, ContentsContext) -> Set<ShapeID>,
        _ row: @escaping @MainActor (ShapeRecord<P>, ContentsContext) -> ContentsLabel
    ) {
        contribute(ContentsContribution(P.self, isListed: isListed, parent: parent, affected: affected, row: row),
                   to: ContentsRows.self, for: .kind(P.kind))
    }

    /// What the rows of a kind another plugin registers are called (bridges), as above.
    public mutating func contentsTitle<P: ShapeProps>(_: P.Type, _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        contribute({ $0.typed(as: P.self).flatMap(make) }, to: ContentsTitles.self, for: .kind(P.kind))
    }

    /// A mark on every shape's row, where `make` gives one (nil for none), from the shape and the
    /// editor's services; `where` (a `ContentsKind`, asked once per kind) keeps it to the kinds
    /// that opted into what it marks, as Locking's lock goes only on kinds that can be locked:
    ///
    ///     registrar.contentsMarkForEveryShape(where: { $0.holds(LockedProperty.self) }) { shape, _ in
    ///         shape.isLocked ? ContentsMark(symbol: "lock.fill", color: .secondary, help: "Locked") : nil
    ///     }
    ///
    /// A mark read from more than the shape (a horizontal's engine, which looks at other shapes)
    /// names, with `affected`, the shapes whose marks a commit may change besides those it changes:
    ///
    ///     registrar.contentsMarkForEveryShape(affected: { changes, context in
    ///         context.service(ValidationEngine.self)?.affected(by: changes) ?? []
    ///     }) { shape, context in ... }
    public mutating func contentsMarkForEveryShape(
        where appliesTo: @escaping @MainActor (ContentsKind) -> Bool = { _ in true },
        affected: (@MainActor (ChangeSet, ContentsContext) -> Set<ShapeID>)? = nil,
        _ make: @escaping @MainActor (AnyShapeRecord, ContentsContext) -> ContentsMark?
    ) {
        contribute(ContentsMarkContribution(affected: affected, where: appliesTo, make), to: ContentsMarks.self, for: .any)
    }
}

// MARK: The row

/// The row most kinds want, as a Mac source list shows one: a symbol, a title on one line, and a count
/// or short note at the trailing end. A blank title shows `placeholder`, dimmed. Without a symbol
/// of its own, the row shows its kind's (`registry.label(of:)`).
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

    /// The row's tooltip: its text, for a row the list cuts short (notes that begin alike), up to
    /// `ContentsStyle.helpLength` characters, cut between words with "…" past that (a note's whole
    /// pasted page would be a help tag down the screen); none for a placeholder, which says nothing
    /// more, or for no text.
    public var help: String? {
        let text = text
        guard !isPlaceholder, !text.isEmpty else { return nil }
        guard text.count > ContentsStyle.helpLength else { return text }
        let end = text.index(text.startIndex, offsetBy: ContentsStyle.helpLength)
        let head = text[..<end]
        let cut = text[end] == " " ? head : head[..<(head.lastIndex(of: " ") ?? head.endIndex)]
        return cut + "…"
    }

    /// The same label, called `title` (`ContentsTitles`).
    func retitled(_ title: String) -> ContentsLabel {
        ContentsLabel(title, placeholder: placeholder, systemImage: systemImage, color: color, badge: badge)
    }

    /// Whether `other` shows what this does: the same title, placeholder, symbol, color and badge.
    func showsSame(as other: ContentsLabel) -> Bool {
        title == other.title && placeholder == other.placeholder && systemImage == other.systemImage && color == other.color
            && badge == other.badge
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
        .help(help ?? "")
    }
}

/// The symbol of the row's kind (`registry.label(of:)`), which a `ContentsLabel` without its own shows.
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
/// by its label and symbol (`registry.label(of:)`).
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
    /// The most of a row's text its tooltip shows (`ContentsLabel.help`): enough to tell apart rows
    /// that begin alike.
    static let helpLength = 200
    /// The header's: between the up button, the heading's symbol and its title; the up button's width.
    static let headerSpacing: CGFloat = 4
    static let upWidth: CGFloat = 16
    /// The up button's: an arrow that turns up, a way out as Finder's enclosing folder is, not a disclosure.
    static let upSymbol = "arrow.turn.left.up"
    /// A mark's dot, a mark's symbol, and the square around either that its tooltip answers in.
    static let markSize: CGFloat = 6
    static let markSymbolSize: CGFloat = 9
    static let markTarget: CGFloat = 12
    /// A hovered row's tint, in the selection highlight's place: inset from the row's sides, with
    /// its corners.
    static let hoverOpacity: CGFloat = 0.14
    static let highlightInset: CGFloat = 10
    static let highlightRadius: CGFloat = 8
    /// The outline's (`ContentsOutline`): its rows, all of one height; how far each level of nesting
    /// goes in, and the disclosure triangle's column; the row under the pointer's light, and the
    /// corners of it and of the highlight; the symbol's column, and from it to the title.
    static let outlineRowHeight: CGFloat = 24
    static let outlineIndent: CGFloat = 14
    static let outlineDisclosureWidth: CGFloat = 14
    static let outlineDisclosureSize: CGFloat = 9
    static let outlineRowPadding: CGFloat = 6
    static let outlineHoverOpacity: CGFloat = 0.08
    static let outlineRadius: CGFloat = 6
    static let outlineIconWidth: CGFloat = 18
    static let outlineIconSpacing: CGFloat = 5
}
