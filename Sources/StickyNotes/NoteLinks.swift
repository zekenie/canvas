import AppKit
import Canvas
import Ports

/// What a note's ports draw: a link from a note to a note, the only connection a note takes. It says
/// nothing more yet; a channel is where a connection's meaning would go (data-canvas's `references`).
public enum NoteLink {}

extension NoteLink: Channel {
    public static let id: ChannelID = "note-link"
    /// A brown amber, darker than the note, so a dot reads beside one.
    public static var color: NSColor { NSColor(srgbRed: 0.70, green: 0.45, blue: 0.05, alpha: 1) }
}

extension ShapeRegistrar where Definition == StickyNoteDefinition {
    /// Ports on every side but the top, where a titled note's pill is.
    mutating func noteLinks() {
        ports(NoteLink.self, sides: [.left, .right, .bottom])
    }
}
