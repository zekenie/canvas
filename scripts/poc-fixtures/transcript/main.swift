import AppKit

// Replays each scenario in Tests/CompositionTests/Replay.swift against the POC's CanvasView, with
// real NSEvents and real waits, then prints where every arrow ended up. Built by
// scripts/record-poc-fixtures.sh.

func describe(_ t: ArrowTerminal, _ ids: [ShapeID]) -> String {
    func r(_ v: CGFloat) -> String { String(format: "%.6f", Double(v)) }
    switch t {
    case .free(let p): return "free(\(r(p.x)),\(r(p.y)))"
    case .bound(let b): return "bound(#\(ids.firstIndex(of: b.shapeID).map(String.init) ?? "?"),\(r(b.normalizedAnchor.x)),\(r(b.normalizedAnchor.y)),\(b.isPrecise ? "precise" : "imprecise")\(b.isExact ? ",exact" : ""))"
    }
}

for (name, withArrow, steps) in scenarios {
    let board = Board(withArrow: withArrow)
    board.player.play(steps)
    board.player.sleep(200)
    let canvas = board.canvas
    let ids = [board.a.id, board.b.id]
    let shapes = canvas.shapes.map { s in "#\(ids.firstIndex(of: s.id).map(String.init) ?? "new")@\(s.frame)" }.joined(separator: " ")
    print("\(name): tool=\(canvas.tool) camera=\(canvas.camera.origin) shapes=[\(shapes)]")
    for arrow in canvas.arrows {
        print("    \(describe(arrow.start, ids)) -> \(describe(arrow.end, ids)) bend=\(String(format: "%.6f", Double(arrow.bend))) heads=\(arrow.startArrowhead),\(arrow.endArrowhead)")
    }
}
