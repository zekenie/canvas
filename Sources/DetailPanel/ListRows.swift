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
