import Canvas
import DetailPanel
import SwiftUI
import Titles

extension ShapeRegistrar where Definition == FrameDefinition {
    /// The frame's header in the detail panel: its title, renamed in place ("Untitled Frame" while it
    /// has none), by its symbol.
    mutating func frameHeader() {
        details(header: { $frame in
            TitleHeader($frame, placeholder: Frame.placeholder, systemImage: Frame.systemImage)
        }) {}
    }
}
