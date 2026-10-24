import AppKit
@_spi(Host) import Canvas

/// The view of a card under test (`CanvasCard`): flipped, takes the keyboard, logs the keys it hears,
/// and is as large as it `wants` (cut to the room the host gives it), logging the rooms it is asked
/// about. A key it doesn't take (`keys` only logs the ones `takes` says) goes up the responder chain,
/// as a text view's unbound key would.
public final class CardProbe: NSView {
    /// The characters of each key pressed on it, in order.
    public private(set) var keys: [String] = []
    /// The size it wants, in view points: what `size` answers, cut to the room.
    public var wants = CGSize(width: 200, height: 120)
    /// The rooms the host asked it about, in order.
    public private(set) var asked: [CGSize] = []
    /// Whether it answers a key (and logs it); else the key goes on to the next responder.
    public var takes: (String) -> Bool = { _ in true }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        guard takes(characters) else { return super.keyDown(with: event) }
        keys.append(characters)
    }

    /// What the card's `size` closure answers.
    @MainActor public func size(in room: CGSize) -> CGSize {
        asked.append(room)
        return CGSize(width: min(wants.width, room.width), height: min(wants.height, room.height))
    }

    public func forgetAsked() { asked = [] }
}

/// The closings a card heard (`CanvasCard.didClose`), in order, and what to do as each comes.
@MainActor
public final class ClosingLog {
    public var closings: [CanvasCardClosing] = []
    /// Runs as each closing is heard (what a test reads of the editor then).
    public var heard: (CanvasCardClosing) -> Void = { _ in }
    public init() {}
}

/// A card about `shape`, hung from `anchor`, whose view is `probe`: asked for its size with the room,
/// logging its closings in `closings`; `showsZoomedOut` as a card's.
@MainActor
public func probeCard(_ id: String, about shape: ShapeID? = nil, anchor: CGRect, stepName: String? = nil,
                      adoptsPress: Bool = false, showsZoomedOut: Bool = false, probe: CardProbe, closings: ClosingLog) -> CanvasCard {
    CanvasCard(id: id, about: shape, anchor: anchor, view: probe, firstResponder: probe, stepName: stepName,
               adoptsPress: adoptsPress, showsZoomedOut: showsZoomedOut,
               size: { [unowned probe] in probe.size(in: $0) },
               didClose: { [unowned closings] in
                   closings.closings.append($0)
                   closings.heard($0)
               })
}
