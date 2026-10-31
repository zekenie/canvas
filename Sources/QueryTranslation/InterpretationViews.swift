import AppKit
import Canvas
import DetailPanel
import LanguageModels
import Selection
import SwiftUI

// What every host of words shows of them in the panel, lifted out of References' (a pill's Query and Matches
// sections show them): the query the words became, colored as code and read-only (`InterpretedQueryView`), the
// shapes it found, a row each (`FoundRows`), and the button a status offers (`InterpretationStatus.Action`'s
// `button(retry:)`). A host makes the rows (`FoundRow`): what a shape is called and where it is are its words.

/// The query words became, read-only and colored as code is: one line per line, scrolling sideways, never
/// wrapped.
public struct InterpretedQueryView: View {
    let query: String

    public init(_ query: String) {
        self.query = query
    }

    public var body: some View {
        DetailCodeEditor(.constant(query), height: InterpretationStyle.queryBoxHeight, isEditable: false, coloring: QueryColoring.spans)
    }
}

/// A shape a query found, as its row says it.
public struct FoundRow: Equatable, Identifiable {
    public var id: ShapeID
    public var symbol: String
    public var tint: NSColor?
    public var name: String
    /// Where it is, when that isn't the board shown: the containers it is inside, else its board's name.
    public var place: String?
    /// A row the host shows as what more it could have (a first-match pill's rows after the first).
    public var dimmed: Bool
    /// How far in it is: 1 for a shape a container found holds, listed under it.
    public var depth: Int

    public init(id: ShapeID, symbol: String, tint: NSColor?, name: String, place: String?, dimmed: Bool, depth: Int = 0) {
        self.id = id
        self.symbol = symbol
        self.tint = tint
        self.name = name
        self.place = place
        self.dimmed = dimmed
        self.depth = depth
    }
}

/// What a query found, a row each, then how many more there are. A click on a row is the host's (`follow`);
/// the pointer on one hovers its shape on the canvas, if it's on the board shown.
public struct FoundRows: View {
    let rows: [FoundRow]
    let more: Int
    weak var editor: CanvasEditor?
    let follow: @MainActor (ShapeID) -> Void

    public init(_ rows: [FoundRow], more: Int, editor: CanvasEditor?, follow: @escaping @MainActor (ShapeID) -> Void) {
        self.rows = rows
        self.more = more
        self.editor = editor
        self.follow = follow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                Button { follow(row.id) } label: {
                    DetailShapeRow(symbol: row.symbol, tint: row.tint, name: row.name, detail: row.place, dimmed: row.dimmed)
                        .padding(.leading, CGFloat(row.depth) * InterpretationStyle.heldIndent)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .onHover { inside in
                    if inside { hover(row.id) } else { endHover(row.id) }
                }
                .onDisappear { endHover(row.id) }
            }
            if more > 0 {
                Text(InterpretationWords.more(more))
                    .font(.system(size: InterpretationStyle.captionSize))
                    .foregroundStyle(.secondary)
                    .padding(.leading, InterpretationStyle.moreIndent)
            }
        }
    }

    private func hover(_ id: ShapeID) {
        guard let editor, editor.document[id] != nil else { return }
        editor.hovered = id
    }

    private func endHover(_ id: ShapeID) {
        if editor?.hovered == id { editor?.hovered = nil }
    }
}

extension InterpretationStatus.Action {
    /// The button a status line offers for it: Retry asks again (`retry`), Open Settings… shows where the
    /// model's key is saved.
    @MainActor public func button(retry: @escaping @MainActor () -> Void) -> DetailStatusAction {
        switch self {
        case .retry: DetailStatusAction(InterpretationWords.retry, perform: retry)
        case .openSettings: DetailStatusAction(InterpretationWords.openSettings) { _ = AnthropicSettingsView.showSettings() }
        }
    }
}

/// The panel's measures for words and what they found.
@MainActor
public enum InterpretationStyle {
    /// The query box's least height.
    public static let queryBoxHeight: CGFloat = 20
    /// "and 42 more" under the rows: caption-sized, under their names (past the symbol's column and its gap).
    public static let captionSize: CGFloat = 10
    public static let moreIndent: CGFloat = 16 + 4
    /// The most rows a host lists; past it, how many more there are.
    public static let foundRows = 8
    /// A held shape's row, in from its container's.
    public static let heldIndent: CGFloat = 16
    /// The line under words: its parts apart, its buttons apart, and the sample's arrows.
    public static let previewSpacing: CGFloat = 3
    public static let buttonSpacing: CGFloat = 8
    public static let previousSample = "chevron.left"
    public static let nextSample = "chevron.right"
}

// MARK: Coloring a query

/// A query's runs as code is colored (`DetailCodeSpan`): a kind or an attribute's name as a name, a quoted
/// string as a string, a number as a number, a `:word` as a keyword, and a string left open as what doesn't
/// belong. A scan, not a parse: asked of the whole text as it's shown.
public enum QueryColoring {
    @MainActor public static func spans(_ text: String) -> [DetailCodeSpan] {
        let units = Array(text.utf16)
        var spans: [DetailCodeSpan] = []
        var index = 0
        func isLetter(_ unit: UInt16) -> Bool {
            (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit > 127
        }
        func continues(_ unit: UInt16) -> Bool { isLetter(unit) || (48...57).contains(unit) || unit == 45 }
        while index < units.count {
            let unit = units[index]
            if unit == 34 || unit == 39 {
                let start = index
                index += 1
                while index < units.count, units[index] != unit {
                    if units[index] == 92 { index += 1 }
                    index += 1
                }
                let closed = index < units.count
                index = min(index + 1, units.count)
                spans.append(DetailCodeSpan(closed ? .string : .invalid, NSRange(location: start, length: index - start)))
            } else if unit == 58 {
                let start = index
                index += 1
                while index < units.count, continues(units[index]) { index += 1 }
                spans.append(DetailCodeSpan(.keyword, NSRange(location: start, length: index - start)))
            } else if isLetter(unit) {
                let start = index
                while index < units.count, continues(units[index]) { index += 1 }
                spans.append(DetailCodeSpan(.name, NSRange(location: start, length: index - start)))
            } else if (48...57).contains(unit) {
                let start = index
                while index < units.count, continues(units[index]) || units[index] == 46 { index += 1 }
                spans.append(DetailCodeSpan(.number, NSRange(location: start, length: index - start)))
            } else {
                index += 1
            }
        }
        return spans
    }
}
