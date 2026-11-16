import AppKit

/// What a reach reads of its surroundings, for the app: whether the system asks for less motion, which
/// shows a reach settled rather than a hop at a time. The system's setting, read as a reach shows,
/// unless a test says.
@MainActor
public final class ReachSettings {
    /// The app's: the system's Reduce Motion.
    public static let app = ReachSettings()

    /// Whether the system asks for less motion: no pulse then.
    public var reducesMotion: @MainActor () -> Bool

    /// Settings with `reducesMotion` as the caller says (a test's), the system's by default.
    public init(reducesMotion: @escaping @MainActor () -> Bool = ReachSettings.systemReducesMotion) {
        self.reducesMotion = reducesMotion
    }

    /// The system's Reduce Motion.
    public static func systemReducesMotion() -> Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
