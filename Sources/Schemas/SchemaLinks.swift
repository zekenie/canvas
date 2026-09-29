import AppKit
import Canvas
import Ports

/// What a schema card's ports draw: a link from a schema to a schema, the only connection a card
/// takes, as a note's is a note's. It says nothing more yet; a channel is where a connection's
/// meaning would go (one schema referring to another, say).
public enum SchemaLink {}

extension SchemaLink: Channel {
    public static let id: ChannelID = "schema-link"
    /// The card's accent (`SchemaStyle.accent`), so a dot reads as the card's.
    public static var color: NSColor { NSColor(srgbRed: 0.75, green: 0.18, blue: 0.62, alpha: 1) }
    public static let summary: String? = "an arrow drawn on the schema-link channel"
}

extension ShapeRegistrar where Definition == SchemaCardDefinition {
    /// Ports on all four sides: the card draws its name inside, so nothing sits above it.
    mutating func schemaLinks() {
        ports(SchemaLink.self)
    }
}
