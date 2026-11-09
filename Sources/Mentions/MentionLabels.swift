import Canvas

/// The names mentions show now, taken from Mentions' state in one step (`MentionState.labels`) and
/// read anywhere, on any thread: for each shape mentioned anywhere in the file (or observed), the
/// name its pills show while it's live. So mention text reads as a person reads it
/// (`plainText { labels.label(of: $0) }`) away from the main actor, as the file was when they were
/// taken: a rename after that isn't in them.
public struct MentionLabels: Sendable {
    /// How each shows, as the state kept it: shared with it until either changes.
    private let resolutions: [ShapeID: MentionResolution]
    /// How each mentioned row shows, by its shape.
    private let rows: [ShapeID: [PartID: MentionResolution]]
    /// The name each target last showed live (`SeenNames`), what a mention shows while its target isn't live.
    private let seen: [PartAddress: String]

    /// No names: every mention reads as the name it holds.
    public init() {
        resolutions = [:]
        rows = [:]
        seen = [:]
    }

    init(_ resolutions: [ShapeID: MentionResolution], rows: [ShapeID: [PartID: MentionResolution]], seen: [PartAddress: String]) {
        self.resolutions = resolutions
        self.rows = rows
        self.seen = seen
    }

    /// The name a mention of `target` shows: its shape's, while it's live; while it's missing or unavailable, the name it last
    /// showed, else nil (a mention then shows the name it holds); nil for a shape nothing mentions.
    public func label(of target: ShapeID) -> String? {
        guard let resolution = resolutions[target] else { return nil }
        return resolution.appearance?.label ?? seen[PartAddress(target)]
    }

    /// The name a mention of a row shows (its live full name), or of a shape as a whole (part nil); nil as `label(of:)` says.
    public func label(of target: PartAddress) -> String? {
        guard let part = target.part else { return label(of: target.shape) }
        guard let resolution = rows[target.shape]?[part] else { return nil }
        return resolution.appearance?.label ?? seen[target]
    }
}
