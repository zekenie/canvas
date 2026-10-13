import Canvas
import SwiftUI
import TableOfContents

extension ShapeRegistrar where Definition == FrameDefinition {
    /// The frame's row in the table of contents: its symbol, in its neutral gray or the color it has, and "Untitled
    /// Frame", which Titles replaces with its title once it has one. What it holds is listed under it.
    mutating func frameRow() {
        contentsRow { frame, context in
            ContentsLabel("", placeholder: Frame.placeholder, systemImage: Frame.systemImage, color: context.color(of: frame))
        }
    }
}
