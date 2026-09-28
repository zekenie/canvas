import Canvas
import DetailPanel
import SwiftUI
import Titles

extension ShapeRegistrar where Definition == SubboardDefinition {
    /// The subboard's header in the detail panel: its title, renamed in place ("Untitled Subboard"
    /// while it has none), by its symbol. Boards brings the Board tab with Open.
    mutating func subboardHeader() {
        details(header: { $sub in
            TitleHeader($sub, placeholder: Subboard.placeholder, systemImage: Subboard.systemImage)
        }) {}
    }
}
