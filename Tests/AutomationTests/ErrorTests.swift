import Automation
import Canvas
import CanvasRPC
import CanvasTesting
import TestKit

// What a command's error says to the command line: its reason and hint, and for a command that
// reads a script, where in it, and every problem it found.

/// A registry whose one command, `stumble`, always throws `error`.
@MainActor func stumbling(_ error: AutomationError) throws -> Registry {
    try Registry(plugins: [AutomationPlugin(), Contributor(id: "stumbles") { registrar in
        registrar.automationCommand("stumble", "Fail, as told.", scope: .app, params: NoParams.self) { _, _ throws(AutomationError) -> String in
            throw error
        }
    }])
}

@MainActor let errorTests = Suite("Errors", [
    test("an error says its reason and hint in its data, and nothing more when that's all it knows") {
        let registry = try stumbling(AutomationError("No luck.", reason: "no_luck", hint: "Try again."))
        let result = try run(["stumble"], on: nil, registry: registry)
        guard case .failure(let error) = result else { return expect(false, "it didn't fail") }
        expectEqual(error.code, RPCError.failed)
        expectEqual(error.message, "No luck.")
        expectEqual(error.data, ["reason": "no_luck", "hint": "Try again."])
    },
    test("an error about a script says the line, as written, and every problem found, the first too") {
        let second = AutomationError("\"B\" is written twice, here and on line 2.", reason: "duplicate", line: 4, statement: #"box "B""#)
        let third = AutomationError("A title can't be blank.", reason: "syntax", hint: "Leave it out for an untitled shape.", line: 5,
                                    statement: #"box """#)
        let first = AutomationError("There's no kind boks.", reason: "unknown_kind", hint: "Did you mean box?", line: 1, statement: #"boks "A""#,
                                    errors: [])
        let error = AutomationError(first.message, reason: first.reason, hint: first.hint, line: first.line, statement: first.statement,
                                    errors: [first, second, third])
        guard case .failure(let rpc) = try run(["stumble"], on: nil, registry: stumbling(error)) else { return expect(false, "it didn't fail") }
        expectEqual(rpc.message, "There's no kind boks.")
        expectEqual(rpc.data, [
            "reason": "unknown_kind", "hint": "Did you mean box?", "line": 1, "statement": #"boks "A""#,
            "errors": [
                ["line": 1, "statement": #"boks "A""#, "reason": "unknown_kind", "message": "There's no kind boks.", "hint": "Did you mean box?"],
                ["line": 4, "statement": #"box "B""#, "reason": "duplicate", "message": "\"B\" is written twice, here and on line 2."],
                ["line": 5, "statement": #"box """#, "reason": "syntax", "message": "A title can't be blank.",
                 "hint": "Leave it out for an untitled shape."],
            ],
        ])
    },
    test("an error about the params is invalid params, where it's about a script or not") {
        let error = AutomationError("Nothing to draw.", reason: "empty_script", invalidParams: true, line: 1, statement: "")
        guard case .failure(let rpc) = try run(["stumble"], on: nil, registry: stumbling(error)) else { return expect(false, "it didn't fail") }
        expectEqual(rpc.code, RPCError.invalidParams)
        expectEqual(rpc.data, ["reason": "empty_script", "line": 1, "statement": ""])
    },
])
