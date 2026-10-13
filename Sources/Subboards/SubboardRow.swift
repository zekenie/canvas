import Canvas
import SwiftUI
import TableOfContents

extension ShapeRegistrar where Definition == SubboardDefinition {
    /// The subboard's row in the table of contents: its symbol, in the card's indigo or the color it has, and "Untitled
    /// Subboard", which Titles replaces with its title once it has one. A row reads only its own
    /// shape, so it has no count of what the board holds.
    mutating func subboardRow() {
        contentsRow { subboard, context in
            ContentsLabel("", placeholder: Subboard.placeholder, systemImage: Subboard.systemImage, color: context.color(of: subboard))
        }
    }
}
