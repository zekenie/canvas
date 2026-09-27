import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// The panel's metrics, after Keynote's inspector. Points.
@MainActor
public enum DetailStyle {
    public static let minWidth: CGFloat = 248
    public static let idealWidth: CGFloat = 260
    public static let maxWidth: CGFloat = 340
    static let inset: CGFloat = 16
    static let headerHeight: CGFloat = 44
    static let headerSymbolWidth: CGFloat = 20
    static let backWidth: CGFloat = 20
    static let stripInset: CGFloat = 10
    static let stripBottom: CGFloat = 6
    static let tabHeight: CGFloat = 22
    static let tabSpacing: CGFloat = 2
    static let tabPadding: CGFloat = 5
    static let tabCorner: CGFloat = 5
    static let tabFill = Color.primary.opacity(0.08)
    static let sectionHeaderHeight: CGFloat = 20
    static let sectionTop: CGFloat = 10
    static let sectionBottom: CGFloat = 12
    static let rowSpacing: CGFloat = 8
    static let rowHeight: CGFloat = 20
    static let labelWidth: CGFloat = 72
    static let pairSpacing: CGFloat = 8
    /// Between small things: a chevron and its title, footer lines, swatches.
    static let smallSpacing: CGFloat = 4
    /// Between a number field and its stepper, and its caption.
    static let fieldSpacing: CGFloat = 2
    static let numberWidth: CGFloat = 60
    public static let textAreaHeight: CGFloat = 76
    /// A code editor's least height: a dozen lines. It grows with its lines.
    public static let codeEditorHeight: CGFloat = 280
    /// What a code editor leaves of the panel's height when it's as tall as it gets: room for its
    /// section's title and a line under it.
    static let codeEditorMargin: CGFloat = 64
    /// Lines a code editor counts, at most, to know how tall to be (more than any panel shows).
    static let codeEditorMaxLines = 500
    /// A line of `codeFont`.
    static let codeLineHeight = NSLayoutManager().defaultLineHeight(for: codeFont)
    static let fieldCorner: CGFloat = 4
    /// Where a text view's text starts, from its edge (its line fragment padding).
    static let textInset: CGFloat = 5
    static let listRowHeight: CGFloat = 22
    /// A bordered list's height beyond its rows: its border and inset.
    static let listChrome: CGFloat = 6
    static let listRows = 3...8
    static let listButton = CGSize(width: 22, height: 18)
    static let footerPadding: CGFloat = 8
    static let swatch: CGFloat = 14
    /// The dot in the chosen swatch (System Settings' accent colors).
    static let swatchMark: CGFloat = 6

    static let body = Font.system(size: 11)
    static let caption = Font.system(size: 10)
    static let tab = Font.system(size: 11)
    static let tabSelected = Font.system(size: 11, weight: .semibold)
    static let sectionTitle = Font.system(size: 11, weight: .bold)
    static let headerTitle = Font.system(size: 12, weight: .semibold)
    static let headerSymbol = Font.system(size: 15)
    static let backSymbol = Font.system(size: 13, weight: .semibold)
    static let disclosure = Font.system(size: 8, weight: .bold)
    static let placeholder = Font.system(size: 13)
    /// `body` and a monospaced one, for text views AppKit draws.
    static let bodyFont = NSFont.systemFont(ofSize: 11)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static let info = Color.blue
    static let warning = Color.orange
    static let error = Color.red

    /// A code editor's colors, a role at a time (`DetailCodeSpan`): an editor's, adapting to the
    /// appearance.
    static func codeColor(_ role: DetailCodeSpan.Role) -> NSColor {
        switch role {
        case .name: .systemBlue
        case .string: .systemRed
        case .number: .systemGreen
        case .keyword: .systemPurple
        case .invalid: .systemRed
        }
    }
}

/// What every `LabeledContent` in the panel looks like: the label in a fixed column, so all rows'
/// controls line up, and the control's own label hidden (its placeholder stays).
struct DetailRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DetailStyle.pairSpacing) {
            configuration.label
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: DetailStyle.labelWidth, alignment: .trailing)
            configuration.content
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: DetailStyle.rowHeight)
    }
}

/// Every toggle in the panel is a checkbox. A checkbox lays itself out through the ambient
/// `LabeledContentStyle`, so a standalone one would put its label in the row style's label column;
/// this puts it after the box, as Keynote does. A hidden label (in a row, or `labelsHidden`)
/// stays hidden. Before macOS 15 a style can't tell that its label is hidden, so there a
/// standalone toggle keeps the label column.
struct DetailCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 15, *) {
            Checkbox(configuration: configuration)
        } else {
            Toggle(configuration).toggleStyle(.checkbox)
        }
    }

    @available(macOS 15, *)
    private struct Checkbox: View {
        let configuration: Configuration
        @Environment(\.labelsVisibility) private var labels

        var body: some View {
            if labels == .hidden {
                Toggle(configuration).toggleStyle(.checkbox)
            } else {
                Toggle(configuration).toggleStyle(.checkbox).labeledContentStyle(.automatic)
            }
        }
    }
}

/// Fields side by side, each captioned underneath (Width and Height, X and Y).
public struct DetailFields<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        HStack(alignment: .top, spacing: DetailStyle.pairSpacing) { content }
    }
}

/// A number with its unit in the field ("240 pt"), a stepper, and an optional caption under it.
/// Numbers are shown, and read back, in the environment's locale ("2,5 h" in German; a typed "."
/// is read as the decimal separator too). Typing edits a draft; Return, Tab, leaving the field, or
/// the field going away commits it (one transaction), clamped to `range`. Escape drops the draft
/// and leaves the panel. Stepping writes at once, from the draft if there is one.
public struct DetailNumberField<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    let caption: String?
    @Binding var value: V
    let unit: String
    let range: ClosedRange<V>
    let step: V.Stride
    @State private var draft: String?
    @FocusState private var focused: Bool
    @Environment(\.detailDrafts) private var drafts
    @Environment(\.locale) private var locale

    public init(_ caption: String? = nil, value: Binding<V>, unit: String = "", in range: ClosedRange<V>, step: V.Stride = 1) {
        self.caption = caption
        _value = value
        self.unit = unit
        self.range = range
        self.step = step
    }

    public var body: some View {
        let shown = DetailNumberText.format(Double(value), unit: unit, locale: locale)
        VStack(spacing: DetailStyle.fieldSpacing) {
            HStack(spacing: DetailStyle.fieldSpacing) {
                TextField(caption ?? "", text: Binding(get: { draft ?? shown }, set: { edit($0, shown: shown) }))
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: DetailStyle.numberWidth)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { if !focused { commit() } }
                    .onDisappear(perform: commit)
                Stepper(caption ?? "", onIncrement: { stepBy(step) }, onDecrement: { stepBy(-step) })
            }
            .labelsHidden()
            if let caption {
                Text(caption).font(DetailStyle.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// What's typed is a draft only while it differs from what's shown.
    private func edit(_ text: String, shown: String) {
        draft = text == shown ? nil : text
        if draft == nil { drafts?.pending = nil } else { drafts?.pending = { draft = nil } }
    }

    private func commit() {
        if let number = takeDraft() { value = number }
    }

    /// Steps from what the field shows, a draft included, in one write. A field being typed in
    /// doesn't take a new value, so after a draft it's focused afresh, to show the result.
    private func stepBy(_ delta: V.Stride) {
        let typing = draft != nil
        value = clamped((takeDraft() ?? value).advanced(by: delta))
        if typing {
            focused = false
            Task { focused = true }
        }
    }

    /// Clears the draft, and returns it as a value in `range`; nil if there was none, or it isn't
    /// a number.
    private func takeDraft() -> V? {
        guard let text = draft else { return nil }
        draft = nil
        drafts?.pending = nil
        return DetailNumberText.parse(text, locale: locale).map { clamped(V($0)) }
    }

    private func clamped(_ number: V) -> V { min(max(number, range.lowerBound), range.upperBound) }
}

/// The panel's one uncommitted number, so Escape can drop it before leaving the panel.
@MainActor
final class DraftTracker {
    var pending: (@MainActor () -> Void)?

    func revert() {
        let revert = pending
        pending = nil
        revert?()
    }
}

struct DraftTrackerKey: EnvironmentKey {
    static let defaultValue: DraftTracker? = nil
}

extension EnvironmentValues {
    var detailDrafts: DraftTracker? {
        get { self[DraftTrackerKey.self] }
        set { self[DraftTrackerKey.self] = newValue }
    }
}

/// "240 pt" out; "240", "240pt", " 240 pt " in; nil for anything without a finite number. Both
/// ways in `locale` ("2,5 h" in German), so what's shown reads back as the same number.
public enum DetailNumberText {
    /// Up to two fraction digits, no grouping.
    public static func format(_ value: Double, unit: String, locale: Locale = .current) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale))
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    /// The number before the unit, all of it (a FormatStyle's parse would read "1.2.3" as 1.2). A
    /// "." is a decimal separator in every locale, since numbers are shown without grouping.
    public static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let number = text.trimmingCharacters(in: .whitespaces).prefix { !$0.isLetter && !$0.isWhitespace }
        let reader = NumberFormatter()
        reader.locale = locale
        reader.numberStyle = .decimal
        reader.usesGroupingSeparator = false
        return reader.number(from: number.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? "."))
            .map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil }
    }
}

/// Multiline text in a bordered box, `height` tall, writing on every keystroke. `placeholder` shows,
/// dimmed, while it's empty. With `onCommit`, Return calls it (the text is done: a plugin may act
/// on it), ⇧↩ is a new line, and the keyboard leaving the box calls it too; without, Return is a
/// new line and nothing else happens.
public struct DetailTextArea: View {
    @Binding var text: String
    let height: CGFloat
    let placeholder: String?
    let onCommit: (@MainActor () -> Void)?
    /// What was typed, until the bound value changes. A panel binding reads the snapshot the panel
    /// drew with, and a TextEditor (unlike a TextField) pushes its binding back into the text view
    /// mid-edit, so without this a keystroke typed before the panel redraws would lose the last one.
    @State private var typed: String?

    public init(_ text: Binding<String>, height: CGFloat = DetailStyle.textAreaHeight, placeholder: String? = nil,
                onCommit: (@MainActor () -> Void)? = nil) {
        _text = text
        self.height = height
        self.placeholder = placeholder
        self.onCommit = onCommit
    }

    public var body: some View {
        if let onCommit {
            // Return has to be told from ⇧↩ before the text view takes it: an AppKit text view of
            // the panel's own, which draws the placeholder itself.
            PanelTextView(text: $text, kind: .prose, placeholder: placeholder, isEditable: true, onCommit: onCommit)
                .detailTextBox(height: height)
        } else {
            TextEditor(text: Binding(get: { typed ?? text }, set: { typed = $0; text = $0 }))
                .onChange(of: text) { typed = nil }
                .font(DetailStyle.body)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if let placeholder, (typed ?? text).isEmpty {
                        Text(placeholder)
                            .font(DetailStyle.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, DetailStyle.textInset)
                            .allowsHitTesting(false)
                    }
                }
                .detailTextBox(height: height)
        }
    }
}

/// An editable list in a bordered box, + and − under it (the macOS idiom): drag rows to reorder,
/// select one and press − or Delete to remove it. 3 to 8 rows tall, then it scrolls; empty, it
/// says No Items. Its row selection is view state, so it's fresh for each shape.
public struct DetailList<Item: Identifiable, Row: View>: View {
    @Binding var items: [Item]
    let make: () -> Item
    let row: (Binding<Item>) -> Row
    @State private var selection: Item.ID?

    public init(_ items: Binding<[Item]>, add make: @escaping () -> Item, @ViewBuilder row: @escaping (Binding<Item>) -> Row) {
        _items = items
        self.make = make
        self.row = row
    }

    public var body: some View {
        let rows = min(max(items.count, DetailStyle.listRows.lowerBound), DetailStyle.listRows.upperBound)
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach($items) { $item in
                    row($item)
                        .frame(height: DetailStyle.listRowHeight)
                        .listRowInsets(EdgeInsets())     // the table keeps its own side insets
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            // Rows exactly `listRowHeight` tall: without this and the rows' insets, the list pads
            // each row and makes it at least 24 pt, and the lowest rows no longer fit.
            .environment(\.defaultMinListRowHeight, DetailStyle.listRowHeight)
            .onDeleteCommand(perform: removeSelected)
            // An explicit height: the panel already scrolls.
            .frame(height: DetailStyle.listRowHeight * CGFloat(rows) + DetailStyle.listChrome)
            .overlay {
                if items.isEmpty { Text("No Items").font(DetailStyle.body).foregroundStyle(.secondary).allowsHitTesting(false) }
            }
            HStack(spacing: 0) {
                Button(action: add) { Image(systemName: "plus").frame(width: DetailStyle.listButton.width, height: DetailStyle.listButton.height) }
                    .accessibilityLabel("Add")
                Button(action: removeSelected) { Image(systemName: "minus").frame(width: DetailStyle.listButton.width, height: DetailStyle.listButton.height) }
                    .disabled(selection == nil)
                    .accessibilityLabel("Remove")
                Spacer()
            }
            .buttonStyle(.borderless)
        }
    }

    private func add() {
        let item = make()
        items.append(item)
        selection = item.id
    }

    private func removeSelected() {
        items.removeAll { $0.id == selection }
        selection = nil
    }
}

/// Preset colors, then the system color well (Keynote's fill row). It spans the row, so it goes in
/// a section on its own, not in a `LabeledContent`. The preset equal to `color` is marked; each
/// preset's name is its VoiceOver label.
public struct DetailSwatches: View {
    @Binding var color: CGColor
    let presets: [(name: String, color: CGColor)]

    public init(_ color: Binding<CGColor>, presets: [(name: String, color: CGColor)]) {
        _color = color
        self.presets = presets
    }

    public var body: some View {
        HStack(spacing: DetailStyle.smallSpacing) {
            ForEach(presets.indices, id: \.self) { i in
                let preset = presets[i], isSelected = preset.color == color
                Button { color = preset.color } label: {
                    Circle()
                        .fill(Color(cgColor: preset.color))
                        .frame(width: DetailStyle.swatch, height: DetailStyle.swatch)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.2)))
                        .overlay { if isSelected { Circle().fill(.white).frame(width: DetailStyle.swatchMark) } }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer(minLength: 0)
            // Its label hidden, or the panel's row style would give it a label column.
            ColorPicker("Color", selection: $color, supportsOpacity: false).labelsHidden()
        }
    }
}
