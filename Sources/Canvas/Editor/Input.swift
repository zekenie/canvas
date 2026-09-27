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
    /// A press (or secondary click) made with ⌃ held, by the event alone: `modifiers` also counts
    /// keys let go in the last 150 ms. On the Mac it's the secondary click, which AppKit offers to
    /// the context menu first; a tool that takes it as a click, not ⌃ as a modifier, ignores it.
    public var isControlClick = false
}

/// A key pressed on the canvas, as the plugin that claims key strokes (`registrar.keyStrokes`)
/// gets it: the key's characters as the keyboard's layout types them with no modifier applied but
/// ⇧ (`NSEvent.charactersIgnoringModifiers`: "v", "V" with ⇧, "\u{1b}" for Escape), the modifiers
/// held with it (the event's own), and whether it's a held key repeating.
public struct KeyStroke: Hashable, Sendable {
    public var characters: String
    public var modifiers: Modifiers
    public var isRepeat: Bool

    public init(_ characters: String, modifiers: Modifiers = [], isRepeat: Bool = false) {
        self.characters = characters
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

public enum CanvasCursor: Sendable {
    case standard, crosshair, openHand, closedHand
    /// Over something a click does something with, as a link's or a button's (Selection's canvas
    /// buttons).
    case pointingHand
}

/// Pointer position, smoothed speed and smoothed velocity, from event locations and timestamps.
struct PointerTracker {
    /// View points.
    private(set) var location: CGPoint = .zero
    /// tldraw's pointer smoothing: the old value's weight halves every this many milliseconds.
    static let halfLifeMilliseconds: CGFloat = 16
    /// A speed, or a velocity component, under this (view points per millisecond) reads 0.
    static let restThreshold: CGFloat = 0.01

    /// View points per millisecond, smoothed like tldraw's (see `halfLifeMilliseconds`).
    private(set) var speed: CGFloat = 0
    /// View points per millisecond, per axis, smoothed like `speed` (tldraw's pointer velocity).
    /// Components under `restThreshold` read 0. Reset on every press.
    private(set) var velocity: CGPoint = .zero
    private var lastTime: TimeInterval?

    mutating func resetVelocity() { velocity = .zero }

    mutating func sample(_ point: CGPoint, at time: TimeInterval) {
        defer {
            location = point
            lastTime = time
        }
        guard let lastTime else { return }
        let elapsedMilliseconds = max((time - lastTime) * 1000, 1)
        let weight = 1 - pow(0.5, elapsedMilliseconds / Self.halfLifeMilliseconds)
        let instant = point.distance(to: location) / elapsedMilliseconds
        speed += (instant - speed) * weight
        if speed < Self.restThreshold {
            speed = 0
        }
        velocity = velocity + ((point - location) / elapsedMilliseconds - velocity) * weight
        if abs(velocity.x) < Self.restThreshold { velocity.x = 0 }
        if abs(velocity.y) < Self.restThreshold { velocity.y = 0 }
    }
}
