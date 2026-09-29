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
    /// A press that brings its window forward: the click AppKit lets through to a window that wasn't
    /// key (`acceptsFirstMouse`).
    public var activatesWindow: Bool
    public init(location: CGPoint, timestamp: TimeInterval, modifiers: Modifiers = [], clickCount: Int = 1, activatesWindow: Bool = false) {
        self.location = location
        self.timestamp = timestamp
        self.modifiers = modifiers
        self.clickCount = clickCount
        self.activatesWindow = activatesWindow
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
    /// The press brings its window forward (a click in a window that wasn't key, which AppKit lets
    /// through to the canvas): a click that changes modes on what's selected (the select tool's
    /// click that edits the only selected note) leaves it to the next, as Finder's click-to-rename
    /// ignores it.
    public var activatesWindow = false
}

/// A key pressed on the canvas, as the plugin that claims key strokes (`registrar.keyStrokes`)
/// gets it: the key's characters as the keyboard's layout types them with no modifier applied but
/// ⇧ (`NSEvent.charactersIgnoringModifiers`: "v", "V" with ⇧, "\u{1b}" for Escape), the modifiers
/// held with it (the event's own), and whether it's a held key repeating.
public struct KeyStroke: Hashable, Sendable {
    public var characters: String
    public var modifiers: Modifiers
    public var isRepeat: Bool
    /// For a key of the number row, its digit, whatever the layout types with it: "1" for the key
    /// that types "!" with ⇧ on a US keyboard and "&" alone on a French one. Nil for any other key
    /// (the keypad's too). So a shortcut on a digit and ⇧ (⇧1) is the same key everywhere.
    public var numberRowKey: Character?

    public init(_ characters: String, modifiers: Modifiers = [], isRepeat: Bool = false, numberRowKey: Character? = nil) {
        self.characters = characters
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.numberRowKey = numberRowKey
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

    /// The pointer is at `point`, as something other than its motion says (a gesture where no move
    /// reached the canvas): no speed or velocity comes of the jump, and the next sample starts
    /// afresh from here.
    mutating func relocate(_ point: CGPoint) {
        location = point
        lastTime = nil
        speed = 0
        velocity = .zero
    }

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
