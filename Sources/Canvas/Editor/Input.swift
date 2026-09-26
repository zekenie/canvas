import CoreGraphics
import Foundation
import Geometry

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let command = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)
}

/// What the view reports: view points, `NSEvent.timestamp` seconds, the event's own modifiers.
@_spi(Host) public struct PointerEvent: Sendable {
    public var location: CGPoint
    public var timestamp: TimeInterval
    public var modifiers: Modifiers
    public var clickCount: Int
    public init(location: CGPoint, timestamp: TimeInterval, modifiers: Modifiers = [], clickCount: Int = 1) {
        self.location = location
        self.timestamp = timestamp
        self.modifiers = modifiers
        self.clickCount = clickCount
    }
}

/// What tools and sessions see: resolved through the camera, with modifiers released in the last
/// `Style.modifierReleaseDelay` still held.
public struct Pointer: Sendable {
    /// Where the pointer is, in view points.
    public var view: CGPoint
    /// Where the pointer is, in world units.
    public var world: CGPoint
    public var modifiers: Modifiers
    public var clickCount: Int
}

public enum CanvasCursor: Sendable {
    case standard, crosshair, openHand, closedHand
}

/// Pointer position and smoothed speed, from event locations and timestamps.
struct PointerTracker {
    /// View points.
    private(set) var location: CGPoint = .zero
    /// View points per millisecond, smoothed like tldraw's: the old value's weight halves every 16 ms.
    private(set) var speed: CGFloat = 0
    private var lastTime: TimeInterval?

    mutating func sample(_ point: CGPoint, at time: TimeInterval) {
        defer {
            location = point
            lastTime = time
        }
        guard let lastTime else { return }
        let elapsedMilliseconds = max((time - lastTime) * 1000, 1)
        let instant = point.distance(to: location) / elapsedMilliseconds
        speed += (instant - speed) * (1 - pow(0.5, elapsedMilliseconds / 16))
        if speed < 0.01 {
            speed = 0
        }
    }
}
