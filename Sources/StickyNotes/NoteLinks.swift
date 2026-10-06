import AppKit
import Canvas
import Connections

/// What a note's ports draw: a link between notes, or between a note and a subboard (which takes
/// every channel), the only connection a note takes. It says nothing more yet; a channel is where a
/// connection's meaning would go (data-canvas's `references`).
public enum NoteLink {}

extension NoteLink: Channel {
    public static let id: ChannelID = "note-link"
    /// A brown amber, darker than the note, so a dot reads beside one.
    public static var color: NSColor { NSColor(srgbRed: 0.70, green: 0.45, blue: 0.05, alpha: 1) }
    public static let summary: String? = "an arrow drawn on the note-link channel"
}

extension ShapeRegistrar where Definition == StickyNoteDefinition {
    /// Ports on all four sides, the top too. A titled note's pill is in the row above its top edge, so
    /// a long title runs under the top dot, which draws above it and is pressed before it, as it is
    /// before a lock chip.
    mutating func noteLinks() {
        ports(NoteLink.self)
    }
}
