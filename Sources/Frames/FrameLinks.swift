import AppKit
import Canvas
import Connections

/// What a frame's ports draw: a link from a frame to a frame. A subboard has ports on every channel,
/// so it links to a frame on this one and a frame to it; a note, on its own channel only, doesn't.
/// It says nothing more yet; a channel is where a connection's meaning would go.
public enum FrameLink {}

extension FrameLink: Channel {
    public static let id: ChannelID = "frame-link"
    /// The frame's gray (`FrameStyle.tint`), so a dot reads as the frame's.
    public static var color: NSColor { .systemGray }
    public static let summary: String? = "an arrow drawn on the frame-link channel"
}

extension ShapeRegistrar where Definition == FrameDefinition {
    /// Ports on the right, bottom and left: the top edge is its title's tab, which grabs the frame,
    /// and the arrow leaves from whichever side faces where it goes whatever dot it was drawn from
    /// (it starts at the frame's middle). A frame holding shapes is pressed only on its edge, and
    /// its dots show from there, and go as the pointer goes in among what it holds.
    mutating func frameLinks() {
        ports(FrameLink.self, sides: [.right, .bottom, .left])
    }
}
