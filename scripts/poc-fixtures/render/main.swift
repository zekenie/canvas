import AppKit

// Renders the POC for the pixel-parity tests: the welcome board in three still states, then each
// state in `interactions` (Tests/CompositionTests/Replay.swift), reached with real NSEvents. Built
// by scripts/record-poc-fixtures.sh; writes into the current directory.

@MainActor func save(_ view: NSView, _ name: String) {
    try! snapshot(view).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "poc-\(name).png"))
}

pinAccentColor()

let welcome = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
save(welcome, "welcome")
welcome.selection = .arrow(welcome.arrows[2].id)
save(welcome, "selected-arrow")
welcome.camera.setZoom(0.6, around: CGPoint(x: 300, y: 200))
welcome.selection = .shape(welcome.shapes[1].id)
save(welcome, "zoomed")

for (name, withArrow, steps) in interactions {
    let board = Board(withArrow: withArrow, texts: noteTexts)
    board.player.play(steps)
    save(board.canvas, name)
}
