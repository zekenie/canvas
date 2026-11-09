import Canvas
import CoreGraphics

// The kinds written as lines, as the rest of the module reads them whatever their props are: what their rows are called,
// each row's id and whether it heads a group, the rows a fold keeps (the kind's marks), and where line n is drawn. A kind
// says it once, with `lineRows(_:)` (the module's own source makes the contribution from the kind's `LineModel`).

/// What a kind's rows are called, for VoiceOver and the steps: "column", "columns".
public struct LineNoun: Hashable, Sendable {
    public var singular: String
    public var plural: String

    public init(_ singular: String, plural: String? = nil) {
        self.singular = singular
        self.plural = plural ?? singular + "s"
    }

    /// "Column", "Columns".
    public var title: String { Self.titled(singular) }
    public var pluralTitle: String { Self.titled(plural) }

    /// Each word's first letter capital: "Path Prefix".
    private static func titled(_ words: String) -> String {
        words.split(separator: " ", omittingEmptySubsequences: false).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// "1 column", "37 columns".
    public func counted(_ count: Int) -> String { "\(count) \(count == 1 ? singular : plural)" }
}

/// A row as a fold reads it: its id, and whether it heads the rows after it (a path prefix's header, later).
public struct FoldRow: Hashable, Sendable {
    public let id: PartID
    public let isHeader: Bool

    public init(id: PartID, isHeader: Bool = false) {
        self.id = id
        self.isHeader = isHeader
    }
}

/// The kinds written as lines: one contribution a kind (`lineRows(_:)`). Owner LineRows.
public enum LineRowsKinds {}

extension LineRowsKinds: KeyedExtensionPoint {
    public typealias Contribution = LineRowsContribution
    public static var owner: PluginID { .lineRows }
    public static func uniqueKeys(of _: LineRowsContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of contribution: LineRowsContribution, for target: ShapeTarget) -> String {
        "line rows (\(contribution.noun.plural)) → \(target)"
    }
}

/// One kind's rows as lines, erased: what they're called, each row's id in order, the rows its kind marks (what a fold
/// keeps) and where a line is drawn. Only the sugar makes one.
@MainActor
public struct LineRowsContribution {
    public let noun: LineNoun
    /// The shape's rows, in order; nil for a record of another kind.
    let rows: @MainActor (AnyShapeRecord) -> [FoldRow]?
    /// The rows the kind marks (a table's keys and unique columns), as a layout reads the file.
    let marked: @MainActor (AnyShapeRecord, LayoutReading) -> Set<PartID>
    /// Line n of a shape laid out at a frame, world units.
    let lineRect: @MainActor (Int, CGRect) -> CGRect
    /// A row's card, printed (`CanvasEditor.lineRowCard(of:)`); nil for a row with none.
    let card: @MainActor (CanvasEditor, AnyShapeRecord, PartID) -> LineRowCard?
    /// Whether a row folded away shows while Find is open for hits at these ranges of its text (`LineModel.peeks`).
    let peeks: @MainActor (AnyShapeRecord, PartID, [Range<Int>]) -> Bool
    /// Where a header's opener is on its line (its chevron: the line before its words start), world units, from the header's
    /// index among the shape's rows and its line's rect: a click there opens or closes it, a click on its words selects it.
    let opener: @MainActor (AnyShapeRecord, Int, CGRect) -> CGRect

    public init(noun: LineNoun, rows: @escaping @MainActor (AnyShapeRecord) -> [FoldRow]?,
                marked: @escaping @MainActor (AnyShapeRecord, LayoutReading) -> Set<PartID>,
                lineRect: @escaping @MainActor (Int, CGRect) -> CGRect,
                card: @escaping @MainActor (CanvasEditor, AnyShapeRecord, PartID) -> LineRowCard? = { _, _, _ in nil },
                peeks: @escaping @MainActor (AnyShapeRecord, PartID, [Range<Int>]) -> Bool = { _, _, _ in true },
                opener: @escaping @MainActor (AnyShapeRecord, Int, CGRect) -> CGRect = { _, _, line in line }) {
        self.noun = noun
        self.rows = rows
        self.marked = marked
        self.lineRect = lineRect
        self.card = card
        self.peeks = peeks
        self.opener = opener
    }
}

/// A row's card as text, for what shows what a row holds away from its card (a row's tab in the panel): its header's name, and
/// each line's label and what it says, as the card prints it ("type" "uuid"; "deprecated" "no"; a list's lines one under another).
public struct LineRowCard: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var label: String
        /// What the line says; empty for a line that holds nothing (an empty field, a list with no lines).
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public var name: String
    public var lines: [Line]

    public init(name: String, lines: [Line]) {
        self.name = name
        self.lines = lines
    }
}

extension CanvasEditor {
    /// What a row's card says, printed: its name and each line's label and value, as the card would show them now; nil for a row
    /// of a kind not written as lines, a row its shape doesn't have, or one with no card (an enum's value). The shape on any board
    /// the editor can show.
    public func lineRowCard(of address: PartAddress) -> LineRowCard? {
        guard let part = address.part, let record = document[address.shape] ?? shape(inFile: address.shape),
              let lines = registry.lineRows(of: record.kind) else { return nil }
        return lines.card(self, record, part)
    }
}

extension ShapeCapability {
    /// The kinds whose rows are written as lines (`lineRows(_:)`).
    public static let lineRows = ShapeCapability("written as lines") { kind in
        !kind.registry.contributions(to: LineRowsKinds.self, for: kind.kind).isEmpty
    }
}

extension Registry {
    /// What a kind's rows are called, when they're written as lines; nil for a kind whose aren't.
    public func lineRows(of kind: ShapeKind) -> LineRowsContribution? {
        contributions(to: LineRowsKinds.self, for: kind).first
    }
}
