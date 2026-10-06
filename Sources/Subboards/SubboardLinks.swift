import AppKit
import Canvas
import Connections

/// What a subboard's ports draw: a link from a subboard to a subboard. A subboard has ports on
/// every other channel too (`subboardLinks`), so a note or a schema card links to it on its own
/// channel, and it links to either on theirs. It says nothing more yet; a channel is where a
/// connection's meaning would go.
public enum SubboardLink {}

extension SubboardLink: Channel {
    public static let id: ChannelID = "subboard-link"
    /// The card's indigo (`SubboardStyle.border`), so a dot reads as the card's.
    public static var color: NSColor { .systemIndigo }
    public static let summary: String? = "an arrow drawn on the subboard-link channel"
}

extension ShapeRegistrar where Definition == SubboardDefinition {
    /// Ports on all four sides, the top too, as a schema card's: a long title's pill runs under the
    /// top dot. Its own channel is first, so its dots are indigo (a dot is its first channel's
    /// color) and a drag to another subboard is on it (a drag is drawn on the first of the dot's
    /// channels the shape it ends on takes); every channel there is comes after, so what has ports
    /// on any of them links to a subboard, and a subboard to it.
    mutating func subboardLinks() {
        ports(SubboardLink.self)
        portsOnEveryChannel()
    }
}
