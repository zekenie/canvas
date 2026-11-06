import Canvas
import CanvasRPC
import Draw
import Foundation

// `canvas rehearse`: several scripts drawn in turn on a copy of the board's file (Draw's `Rehearsal`), so a tool that draws a
// plan in several runs knows the whole of it lands before it draws the first.

/// Runs `canvas rehearse`: each script drawn on the copy in a turn of the main actor of its own, so the app goes on between
/// them (the window answers, and what the person does meanwhile reaches the file, never the copy), stopping between two once
/// the request is cancelled. The first script refused is the answer, as `draw` says it, with which one it is (`script`, from 0).
@MainActor
func rehearse(_ params: RehearseParams, program: String, in context: AutomationContext) async throws(AutomationError) -> RehearsalResult {
    let editor = try context.board()
    let scripts = try params.list()
    let rehearsal = Rehearsal(of: editor, program: program)
    var result = RehearsalResult()
    for (index, script) in scripts.enumerated() {
        if index > 0 { await Task.yield() }
        // The server has answered `cancelled` already, and drops what comes after.
        if Task.isCancelled { throw AutomationError("The rehearsal was cancelled before it finished.", reason: "cancelled") }
        do throws(DrawError) {
            result.runs.append(try rehearsal.run(script))
        } catch {
            throw AutomationError(error, script: index)
        }
    }
    return result
}

extension RehearseParams {
    /// The scripts, read from the JSON list they're sent as.
    func list() throws(AutomationError) -> [String] {
        guard let data = scripts.data(using: .utf8), let list = try? JSONDecoder().decode([String].self, from: data) else {
            throw AutomationError("the scripts aren't a JSON list of strings", reason: "invalid_params",
                                  hint: #"give a list of scripts, each as draw takes it: ["note \"A\"", "note \"B\" right of \"A\""]"#,
                                  invalidParams: true)
        }
        return list
    }
}
