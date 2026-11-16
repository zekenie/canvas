import AppKit
import Canvas

extension CanvasCommand {
    /// View › Show Whole Reach: a hover lights everything downstream of the shape (with ⌥, upstream),
    /// each shape fading with its distance, and dims the rest of the board; off, it lights one hop.
    public static let showWholeReach: CanvasCommand = "show-whole-reach"
}

/// Whether a hover shows the whole reach, for the app: View › Show Whole Reach, off until it's turned
/// on, kept between launches in the app's user defaults. Every editor made with these settings follows
/// a change at once (each window's hover lights the other way), as every text follows the spelling
/// settings. And whether the system asks for less motion, which shows a reach settled rather than a hop
/// at a time: the system's setting, read as a reach shows, unless a test says.
@MainActor
public final class ReachSettings {
    /// The app's, kept in the standard user defaults.
    public static let app = ReachSettings(defaults: .standard)

    private let keep: (Bool) -> Void
    private var followers: [Follower] = []
    /// Whether the system asks for less motion: no pulse then.
    public var reducesMotion: @MainActor () -> Bool

    private struct Follower {
        weak var object: AnyObject?
        let changed: @MainActor () -> Void
    }

    /// Settings kept in `defaults` (the app's, `.standard`; a test's own suite).
    public convenience init(defaults: UserDefaults, reducesMotion: @escaping @MainActor () -> Bool = ReachSettings.systemReducesMotion) {
        self.init(showsWholeReach: defaults.bool(forKey: ReachStyle.defaultsKey), keep: { defaults.set($0, forKey: ReachStyle.defaultsKey) },
                  reducesMotion: reducesMotion)
    }

    /// Settings kept nowhere but here: a test's, or a list's that keeps nothing.
    public init(showsWholeReach: Bool = false, keep: @escaping (Bool) -> Void = { _ in },
                reducesMotion: @escaping @MainActor () -> Bool = ReachSettings.systemReducesMotion) {
        self.showsWholeReach = showsWholeReach
        self.keep = keep
        self.reducesMotion = reducesMotion
    }

    /// Show Whole Reach: a hover lights the reach, not one hop. Kept as it's set, and every follower told.
    public var showsWholeReach: Bool {
        didSet {
            guard showsWholeReach != oldValue else { return }
            keep(showsWholeReach)
            followers.removeAll { $0.object == nil }
            for follower in followers { follower.changed() }
        }
    }

    /// The system's Reduce Motion.
    public static func systemReducesMotion() -> Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `object` is told of every change while it lives.
    func follow(_ object: AnyObject, _ changed: @escaping @MainActor () -> Void) {
        followers.removeAll { $0.object == nil }
        followers.append(Follower(object: object, changed: changed))
    }
}
