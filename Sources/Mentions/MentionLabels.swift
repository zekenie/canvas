import Canvas

/// The names mentions show now, taken from Mentions' state in one step (`MentionState.labels`) and
/// read anywhere, on any thread: for each shape mentioned anywhere in the file (or observed), the
/// name its pills show while it's live. So mention text reads as a person reads it
/// (`plainText { labels.label(of: $0) }`) away from the main actor, as the file was when they were
/// taken: a rename after that isn't in them.
public struct MentionLabels: Sendable {
    /// How each shows, as the state kept it: shared with it until either changes.
    private let resolutions: [ShapeID: MentionResolution]

    /// No names: every mention reads as the name it holds.
    public init() { resolutions = [:] }

    init(_ resolutions: [ShapeID: MentionResolution]) { self.resolutions = resolutions }

    /// The name a mention of `target` shows: its shape's, while it's live; nil while it's missing or
    /// unavailable (a mention then shows the name it holds), and for a shape nothing mentions.
    public func label(of target: ShapeID) -> String? { resolutions[target]?.appearance?.label }
}
