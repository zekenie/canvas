import Canvas
import SwiftUI
import TableOfContents

extension ShapeRegistrar where Definition == ArrowDefinition {
    /// The arrow's row in the table of contents, under the shape it starts from (as data-canvas's
    /// edges): its label's first line, else "Arrow", dimmed.
    mutating func arrowRow() {
        contentsRow(nestedUnder: { $0.props.start.binding?.shapeID }) { arrow in
            ContentsLabel(arrow.props.firstLine ?? "", placeholder: "Arrow", systemImage: ArrowStyle.symbol)
        }
    }
}

extension Arrow {
    /// The first line of its text that says something, trimmed; nil for none.
    var firstLine: String? {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
