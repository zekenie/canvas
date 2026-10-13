import AppKit
import SwiftUI

/// A checkbox with its title after it, for a `LabeledContent` row's content ("Label [] Title"): a
/// label-hidden toggle beside a `Text` that toggles on a click, so the row reads alike on macOS 14,
/// where the checkbox style puts a toggle's own label in the row's label column, and on 15, where it
/// doesn't.
public struct DetailCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    public var body: some View {
        HStack(spacing: DetailStyle.smallSpacing) {
            Toggle(title, isOn: $isOn).labelsHidden()
            Text(title)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { isOn.toggle() }
        }
    }
}

/// A row for a shape in a panel's list, laid out as the panel's status lines are: the kind's symbol
/// (in `tint`, else secondary) in the status icon's column, then the shape's `name` on one line in the
/// panel's text size, with an optional `detail` at the end of it and up to two `lines` of caption
/// text under it. A `dimmed` row (a shape that can't be gone to, say) is all dimmed, its secondary
/// text with it. The row is a plain view: wrap it in a `Button` to make it one.
public struct DetailShapeRow: View {
    let symbol: String
    let tint: NSColor?
    let name: String
    let detail: String?
    let lines: [String]
    let dimmed: Bool

    public init(symbol: String, tint: NSColor? = nil, name: String, detail: String? = nil, lines: [String] = [], dimmed: Bool = false) {
        self.symbol = symbol
        self.tint = tint
        self.name = name
        self.detail = detail
        self.lines = Array(lines.prefix(DetailStyle.shapeRowLines))
        self.dimmed = dimmed
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DetailStyle.smallSpacing) {
            Image(systemName: symbol)
                .foregroundStyle(tint.map { Color(nsColor: $0) } ?? Color.secondary)
                .frame(width: DetailStyle.statusIconWidth)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: DetailStyle.pairSpacing) {
                    Text(name).font(DetailStyle.body).lineLimit(1)
                    if let detail {
                        Spacer(minLength: 0)
                        Text(detail).font(DetailStyle.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i]).font(DetailStyle.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: DetailStyle.listRowHeight, alignment: .top)
        .opacity(dimmed ? DetailStyle.dimmedRow : 1)
        .contentShape(Rectangle())
    }
}

/// The head of a list of rows inside a section, which folds it: a disclosure triangle and the title,
/// set as a section's are, with a dot in `tint` between them when the list has a color of its own,
/// and how many rows the list has after it. The caller keeps whether it's folded, and leaves the
/// rows out while it is.
public struct DetailGroupHeader: View {
    let title: String
    let count: Int?
    let tint: NSColor?
    let isCollapsed: Bool
    let toggle: @MainActor () -> Void

    public init(_ title: String, count: Int? = nil, tint: NSColor? = nil, isCollapsed: Bool, toggle: @escaping @MainActor () -> Void) {
        self.title = title
        self.count = count
        self.tint = tint
        self.isCollapsed = isCollapsed
        self.toggle = toggle
    }

    public var body: some View {
        Button(action: toggle) {
            HStack(spacing: DetailStyle.smallSpacing) {
                Image(systemName: "chevron.right")
                    .font(DetailStyle.disclosure)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                if let tint {
                    Circle().fill(Color(nsColor: tint)).frame(width: DetailStyle.groupDot, height: DetailStyle.groupDot)
                }
                Text(title).font(DetailStyle.sectionTitle).lineLimit(1)
                if let count {
                    Text("\(count)").font(DetailStyle.body).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(height: DetailStyle.sectionHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .accessibilityLabel(title)
        .accessibilityValue(count.map { "\($0)" } ?? "")
    }
}

/// A field that searches a list in the panel: a magnifying glass, the text, typed as keyed (nothing
/// corrected), and, once there's text, a button that clears it. Escape, as anywhere in the panel,
/// gives the keyboard back to the canvas.
public struct DetailSearchField: View {
    let prompt: String
    @Binding var text: String

    public init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        _text = text
    }

    public var body: some View {
        HStack(spacing: DetailStyle.smallSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, DetailStyle.textInset)
        .frame(height: DetailStyle.listRowHeight)
        .background(RoundedRectangle(cornerRadius: DetailStyle.fieldCorner).fill(DetailStyle.searchFill))
    }
}
