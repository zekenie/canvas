import Canvas
import CanvasRPC
import Draw

// The command line's own commands: what any board can do whatever's installed. `draw` puts shapes
// on a board from a script; `kinds` says what a script can draw, and with what; `measure` says how
// big a script's shapes would be. Each is the draw engine's (Draw) behind the command line: it finds
// the board, hands the engine the script, and says what the engine did, or why it couldn't, as the
// wire does. Other plugins add theirs with `registrar.automationCommand`.

public struct AutomationPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .automation }

    public func register(into registrar: inout PluginRegistrar) {
        let canvas = RPC.commandName
        registrar.automationCommand(
            "draw", "Draw shapes on a board, and connect them, from a script.",
            discussion: """
                A script is one statement a line: a shape (its kind, its title in double quotes, its attributes and \
                where it goes against other shapes: right of "API"), an edge (edge "API" -> "DB"), a delete, a group \
                (group "API" and "DB": a click on one selects both; ungroup "API" takes it out), or a \
                style. A statement about a title the board has changes that shape; one about a title it doesn't \
                makes a new one. A shape with no title is named by its id (#<id>), the one a query's row gives, \
                where a statement names a shape that's there: it never makes one. It's applied all at once, as one step of the app's undo, or not at all, and the \
                result says what each statement did and where its shape landed. A title names a shape on any board \
                of the file (the one the window shows first), and in "X" puts a shape on the board X holds (a \
                subboard's), or in X, where X holds shapes on its own board (a frame's): a run draws on the board \
                what it names is on, else the one the window shows, without \
                moving the window (the result's on says which). An edge to a shape on another board goes into a \
                reference to it, put beside the shape on this board, when the shape is public (via: reference asks \
                for one on a single board too). The language is taught \
                by the repository's canvas skill (.claude/skills/canvas); `\(canvas) kinds` lists what can be drawn, \
                and with what.
                """,
            params: DrawParams.self, positionals: ["script"],
            // No kind by name: this plugin knows none, and the kinds are whatever's installed.
            examples: [
                CommandExample(#"\#(canvas) draw '<kind> "API"'"#, "A shape titled API, as near the middle of the view as there's room."),
                CommandExample(#"\#(canvas) draw '<kind> "DB" below "API"'"#, "Another, below it."),
                CommandExample(#"\#(canvas) draw 'edge "API" -> "DB"'"#, "Connect the two."),
                CommandExample(#"\#(canvas) draw 'delete "DB"'"#, "Delete one, and what connects to it."),
                CommandExample(#"\#(canvas) draw 'group "API" and "DB"'"#, "Put the two in one group: a click on either selects both."),
                CommandExample(#"\#(canvas) draw '<kind> "Cache" in "Backend"'"#, "A shape on the board of the subboard titled Backend."),
                CommandExample("\(canvas) draw --dry-run - < plan.txt", "Read the script from standard input, and say what it would do."),
            ]
        ) { params, context throws(AutomationError) in
            let editor = try context.board()
            do throws(DrawError) {
                return try draw(script: params.script, dryRun: params.dryRun, reveal: params.reveal, program: canvas, in: editor)
            } catch {
                throw AutomationError(error)
            }
        }
        registrar.automationCommand(
            "show", "Show another board of the file in its window: a subboard's, by its title, or the top one.",
            discussion: """
                Moves the window, as opening a subboard does; it changes nothing on any board, and the board left is \
                a step of Go › Back. Drawing doesn't need it: a script draws on the board its titles are on, and \
                in "X" puts a shape on the board X holds.
                """,
            params: ShowParams.self, positionals: ["shape"],
            examples: [
                CommandExample(#"\#(canvas) show "Q3""#, "Show the board the shape titled Q3 holds."),
                CommandExample("\(canvas) show --root", "Show the board at the top of the file."),
            ]
        ) { params, context throws(AutomationError) in
            try show(params, in: context)
        }
        registrar.automationCommand(
            "kinds", "List the kinds of shape the app has: what a script can draw, and with what.",
            discussion: """
                For each kind: whether a script can draw it (and why not), whether its shapes have titles of their own \
                (named), worked out from them (derived) or none, the size its tool places, what its shapes hold for \
                in "X" to name (a board of its own, or shapes on the board it's on), each attribute a script can \
                write and what it takes, and the sides an edge may leave it by, with what it may carry from each. \
                --schema adds each kind's JSON Schema (draft 2020-12): every property, what it takes, its default and \
                its bounds.
                """,
            scope: .app, params: ListKinds.self, positionals: ["kind"],
            examples: [
                CommandExample("\(canvas) kinds", "Every kind, and what a script can write on it."),
                CommandExample("\(canvas) kinds <kind> --schema", "One kind, with its JSON Schema."),
            ]
        ) { params, context throws(AutomationError) in
            do throws(DrawError) {
                return try kinds(named: params.kind, schema: params.schema, in: context.registry)
            } catch {
                throw AutomationError(error)
            }
        }
        registrar.automationCommand(
            "measure", "Say how big a draw script's shapes would be, and what they reach, without drawing it.",
            discussion: """
                Takes a script as `draw` does and answers for each shape statement the size draw would make it \
                (a note as tall as its text at its width), how far its title's pill and chips reach above it, and, \
                for each edge that says via:, the size of the reference draw would put beside its start; and the \
                constants placement is done with (every named gap, the step between references, how far in a \
                frame's content sits, the smallest sizes). Where shapes go is ignored. It changes nothing and opens \
                no undo step, so a tool can lay shapes out before it draws them. Every shape is new, whatever a board \
                holds. With a board (the one in front, or --board), an is: finds a type of that board's file as draw \
                does, and the shape is measured with its rows; with none open, only a type the script draws. A name \
                it can't find (an is:, a mention) is a warning, and the shape is measured without it, or with the \
                text as written.
                """,
            scope: .board, boardOptional: true, params: MeasureParams.self, positionals: ["script"],
            examples: [
                CommandExample("\(canvas) measure - < plan.txt", "Read the script from standard input, and say how big each shape would be."),
            ]
        ) { params, context throws(AutomationError) in
            do throws(DrawError) {
                return try measure(script: params.script, program: canvas, in: context.registry, namesBeyond: context.editor)
            } catch {
                throw AutomationError(error)
            }
        }
        // The app's command server runs them all, every plugin's: what the command line shows of
        // each, and each by name.
        registrar.hostCommands(specs: { $0.automationCommands }) { registry, name, params, editor async throws(RPCError) in
            try await registry.runAutomationCommand(name, params: params, editor: editor)
        }
    }
}
