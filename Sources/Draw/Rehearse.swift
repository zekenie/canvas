import Canvas
import Foundation

// A rehearsal (`canvas rehearse`, Automation's): scripts drawn in turn on a copy of an editor's file, so a plan drawn in
// several runs (canvas-digest's, a run a board) is known to land whole before its first run is drawn. Each script is drawn
// as `draw` draws it, on the board as the scripts before it leave it, and what it says is said as a dry run of it says it;
// nothing reaches the file.

/// A copy of an editor's file as it is when the rehearsal begins (`editor.rehearsal()`: the board it shows, through its
/// view), that scripts are drawn on in turn.
@MainActor
public final class Rehearsal {
    private let copy: CanvasEditor
    private let program: String
    /// The ids of the shapes the copy made, which the file never gets: no row or warning of the rehearsal says one.
    private var made: Set<String> = []

    /// What a warning calls a shape the copy made, where it would name it by its id.
    static let madeName = "a shape an earlier script made"

    /// A rehearsal over the file `editor` has now; `program` is the name hints give the command line, as `draw`'s.
    public init(of editor: CanvasEditor, program: String) {
        copy = editor.rehearsal()
        self.program = program
    }

    /// Draws `script` on the copy, after the scripts drawn before it, as `draw` would draw it there, and says what it did as
    /// a dry run of it says it: `dryRun`, and no id the file won't have, for a shape this script makes or one an earlier
    /// script made that this one restates, nor in a warning that would name such a shape by its id. A script refused leaves
    /// the copy as it was.
    public func run(_ script: String) throws(DrawError) -> DrawResult {
        var result = try draw(script: script, dryRun: false, reveal: false, program: program, in: copy)
        for row in result.changes where row.did == .created {
            if let id = row.id { made.insert(id) }
        }
        result.changes = result.changes.map { row in
            var row = row
            if let id = row.id, made.contains(id) { row.id = nil }
            return row
        }
        if !made.isEmpty {
            result.warnings = result.warnings.map { warning in
                var warning = warning
                warning.message = unnamingMade(warning.message)
                return warning
            }
        }
        result.dryRun = true
        return result
    }

    /// `text` with each `#<id>` of a shape the copy made said as `madeName`: the id is the copy's, which the file never gets.
    private func unnamingMade(_ text: String) -> String {
        guard text.contains("#") else { return text }
        var out = text
        for id in made where out.contains("#" + id) {
            out = out.replacingOccurrences(of: "#" + id, with: Self.madeName)
        }
        return out
    }
}

/// What a rehearsal said: each script's result, in order.
public struct RehearsalResult: Encodable, Sendable {
    public var runs: [DrawResult]

    public init(runs: [DrawResult] = []) {
        self.runs = runs
    }
}
