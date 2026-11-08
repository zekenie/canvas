import AppKit
import Connections
import Foundation
import Palette

// What an API does with tables and other endpoints: three channels, each a connection's relation (arrow-look 2.1). `writes` and
// `reads` start at an endpoint's row and end on a table as a whole; `calls` ends on an endpoint's row, and any kind with dots on
// its sides may start one (a note, a frame, a subboard: the storefront that calls the API), as can an endpoint. Each has a title,
// its pill on the line and its row in the list a release opens where several fit (an endpoint let go on a table: writes, reads),
// in its tint, white words on it; lines stay ink (departure 9). The tints are Palette's of the frames' hues (decided 25): reads
// green, writes pink, calls blue, each made dark enough for its white words at 4.5, which reads at 3 on both canvases; calls'
// blue turned off the accent's hue, so a lit calls ring is never read as the selection (the Connections tab lights' rule).

/// An endpoint writes a table: an arrow from the endpoint's row to the table.
public enum Writes {}

extension Writes: Channel {
    public static let id: ChannelID = "writes"
    public static var color: NSColor { NSColor(KitStyle.writesTint) }
    public static let summary: String? = "an endpoint writes a table: an arrow from the endpoint's row to the table"
    public static var title: String? { KitStyle.writesTitle }
    /// Only tables take it, and only endpoints start it: a subboard, open to every channel, is no table.
    public static var isOnEveryChannel: Bool { false }
}

/// An endpoint reads a table: an arrow from the endpoint's row to the table.
public enum Reads {}

extension Reads: Channel {
    public static let id: ChannelID = "reads"
    public static var color: NSColor { NSColor(KitStyle.readsTint) }
    public static let summary: String? = "an endpoint reads a table: an arrow from the endpoint's row to the table"
    public static var title: String? { KitStyle.readsTitle }
    public static var isOnEveryChannel: Bool { false }
}

/// Something calls an endpoint: an arrow to the endpoint's row, from another endpoint or from any shape with dots.
public enum Calls {}

extension Calls: Channel {
    public static let id: ChannelID = "calls"
    public static var color: NSColor { NSColor(KitStyle.callsTint) }
    public static let summary: String? = "something calls an endpoint: an arrow to the endpoint's row"
    public static var title: String? { KitStyle.callsTitle }
    /// A note, a frame or a subboard calls an API as readily as an endpoint does.
    public static var anyKindMayStart: Bool { true }
}

extension KitStyle {
    /// The relations' words: their pills' and their rows' in a release's list.
    nonisolated public static let writesTitle = "writes"
    nonisolated public static let readsTitle = "reads"
    nonisolated public static let callsTitle = "calls"

    /// The frames' hues of the relations.
    nonisolated static let readsHue = RGB(hex: 0x3A9E4F)
    nonisolated static let writesHue = RGB(hex: 0xD23D86)
    nonisolated static let callsHue = RGB(hex: 0x2C72DB)
    /// The app's accent (the system's default blue), which a light's color keeps clear of.
    nonisolated public static let accentBlue = RGB(hex: 0x007AFF)
    /// How far (radians of OKLCH's hue) a relation's color keeps from the accent's: 16°.
    nonisolated public static let accentClearance = 16.0 * Double.pi / 180

    /// A relation's pill and dots: its hue made dark enough for white words at 4.5, the same in both appearances.
    nonisolated public static let readsTint = Swatch.reading(readsHue, against: [.white], atLeast: Swatch.textContrast)
    nonisolated public static let writesTint = Swatch.reading(writesHue, against: [.white], atLeast: Swatch.textContrast)
    /// Calls' blue is the accent's hue (1.4° off): turned off it, toward cyan, by the clearance.
    nonisolated public static let callsTint: RGB = {
        var color = OKLCH(callsHue)
        color.hue = OKLCH(accentBlue).hue - accentClearance
        return Swatch.reading(color.rgb, against: [.white], atLeast: Swatch.textContrast)
    }()
}
