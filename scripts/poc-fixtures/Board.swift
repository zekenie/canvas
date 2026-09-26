import AppKit

// The POC's side of Tests/CompositionTests/Replay.swift: the POC's canvas set up for a scenario,
// with a player that runs the POC's timers (Task.sleeps) on real time. Built by
// scripts/record-poc-fixtures.sh against 804db97.

@MainActor
struct Board {
    let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let a: StickyNote
    let b: StickyNote
    let player: Player

    /// Two notes, and an arrow between their centers with this bend, if given.
    init(withArrow bend: CGFloat?, texts: (String, String) = ("", "")) {
        let a = StickyNote(frame: A, text: texts.0), b = StickyNote(frame: B, text: texts.1)
        (self.a, self.b) = (a, b)
        let canvas = canvas
        canvas.shapes = [a, b]
        func bound(_ n: StickyNote) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: n.id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        canvas.arrows = bend.map { [Arrow(start: bound(a), end: bound(b), bend: $0)] } ?? []
        canvas.selection = nil
        player = Player(canvas, wait: { ms in
            RunLoop.main.run(until: Date().addingTimeInterval(Double(ms) / 1000))
        }, direct: { step in
            switch step {
            case .selectArrow(let i): canvas.selection = .arrow(canvas.arrows[i].id)
            case .selectShape(let i): canvas.selection = .shape(canvas.shapes[i].id)
            case .zoom(let zoom, let anchor): canvas.camera.setZoom(zoom, around: anchor)
            default: fatalError("\(step) is an event")
            }
        })
    }
}
