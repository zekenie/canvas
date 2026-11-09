import Canvas

/// The name each target last showed while it was live, to a mention's pill or a reference's: what a dead one shows, so a
/// trace that a deleted shape leaves is the name the person last saw, never the one the text was written with before a rename
/// (the text holds a mention's name as written, and a rename writes nothing to it). Kept for the session, by what was shown
/// (a pill noting its live name as it is made or shown again), so a pill never drawn since a rename holds the name it showed.
/// Costs a look-up where a pill is made, and the ids it holds are bounded: past `most` it starts again.
@MainActor
public final class SeenNames {
    public static let shared = SeenNames()

    private var names: [PartAddress: String] = [:]
    static let most = 8192

    init() {}

    /// `target` shows `label` while live.
    public func note(_ target: PartAddress, _ label: String) {
        guard names[target] != label, !label.isEmpty else { return }
        if names.count >= Self.most { names.removeAll(keepingCapacity: true) }
        names[target] = label
    }

    /// The name `target` last showed live, if it did.
    public func seen(_ target: PartAddress) -> String? { names[target] }

    /// Every name, to read anywhere (`MentionLabels`): a copy shared with this until the next name is noted.
    var all: [PartAddress: String] { names }

    /// Forgets every name: a test's ids are the next test's, under other names.
    public func forgetAll() { names.removeAll() }

    /// What a dead pill shows: the name last seen, else `stored`, the one it was written with.
    public func held(_ target: PartAddress, stored: String) -> String { names[target] ?? stored }
}
