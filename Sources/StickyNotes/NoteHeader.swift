import Canvas
import DetailPanel
import SwiftUI
import Titles

extension ShapeRegistrar where Definition == StickyNoteDefinition {
    /// The note's header in the detail panel: its title, renamed in place ("Note" while it has none).
    mutating func noteHeader() {
        details(header: { $note in TitleHeader($note) }) {}
    }
}
