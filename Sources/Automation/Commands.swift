import Canvas
import CanvasRPC
import Draw

// The command line's own commands: what any board can do whatever's installed. `draw` puts shapes
// on a board from a script; `rehearse` draws several in turn on a copy of the file (Rehearse.swift);
// `kinds` says what a script can draw, and with what; `measure` says how big a script's shapes would
// be. Each is the draw engine's (Draw) behind the command line: it finds
// the board, hands the engine the script, and says what the engine did, or why it couldn't, as the
// wire does. `show` moves the window to another board (Show.swift), and `capture` takes a picture of
// one (Capture.swift), each finding shapes by the engine's names. Other plugins add theirs with
// `registrar.automationCommand`.

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
                return try draw(script: params.script, dryRun: params.dryRun, reveal: params.reveal, program: canvas, drawing: params.drawing, in: editor)
            } catch {
                throw AutomationError(error)
            }
        }
        registrar.automationCommand(
            "apply", "Draw a whole document by key, on every board it reaches, in one step, or not at all.",
            discussion: """
                For a program that lays a graph out: a document is JSON, its nodes each with a key of the program's \
                own, a kind, the key of the node that holds it (in), its attributes (props, as draw writes them; a \
                value that names a shape may name a node by its key) and where its room goes (place: at, from its \
                frame's top-left or its board's origin, and size); its edges between keys, each straight or through \
                a pill (place.pill: at, or share). The drawing it names is updated by key: its shapes whose keys are \
                in the document change, new keys' shapes are made, and its shapes whose keys are gone are deleted; \
                nothing outside it is touched. The app puts it in order (what holds shapes first, types before \
                their notes, edges last), draws it on a copy of the file, and takes it in as one step of undo. The \
                result is each key's verdict (created, updated, unchanged) and id, and what a person had changed \
                that it changed again (overrode); a refusal names the key, in the app's words, and changes nothing.
                """,
            params: ApplyParams.self, positionals: ["document"],
            examples: [
                CommandExample("\(canvas) apply --dry-run - < drawing.json", "Say what drawing.json would do, changing nothing."),
                CommandExample("\(canvas) apply - < drawing.json", "Draw it, or bring the drawing it names up to date."),
                CommandExample(#"\#(canvas) apply --on "Proposal" - < drawing.json"#, "Draw its top on the board of the subboard titled Proposal."),
            ]
        ) { params, context throws(AutomationError) in
            let editor = try context.board()
            do throws(DocumentError) {
                return try apply(document: params.document, dryRun: params.dryRun, on: params.on, program: canvas, in: editor)
            } catch {
                throw AutomationError(error)
            }
        }
        registrar.automationCommand(
            "rehearse", "Draw several scripts in turn on a copy of the board's file, and say what each would do, changing nothing.",
            discussion: """
                For a plan drawn in several runs, each on its own board: every script is drawn in order on a copy of \
                the file as it is when the rehearsal begins, so a later one finds what an earlier one made, and the \
                answer is each one's rows and warnings (runs), as a dry run of it would say them on the board as the \
                scripts before it leave it. Nothing changes and no step opens; the app goes on between scripts, and \
                what changes on the board meanwhile isn't in the copy. If one is refused, the error is draw's, with \
                which script it is (script, from 0); the scripts before it were drawn on the copy only.
                """,
            params: RehearseParams.self, positionals: ["scripts"],
            examples: [
                CommandExample("\(canvas) rehearse - < runs.json", "Draw the scripts of runs.json, a JSON list of them, in turn on a copy of the file."),
            ],
            runAsync: { (params: RehearseParams, context: AutomationContext) async throws(AutomationError) -> RehearsalResult in
                try await rehearse(params, program: canvas, in: context)
            })
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
        let limit = CaptureStyle.said(CaptureStyle.limit), view = CaptureStyle.said(CaptureStyle.view)
        registrar.automationCommand(
            "capture", "Take a picture of a board, or of part of one, as the app draws it, in a PNG file.",
            discussion: """
                Draws the board apart from the window, as the canvas shows it with nothing selected: the window \
                doesn't move and needn't be in view, and nothing on any board changes. With no shapes, it's the whole \
                board, fitted, as big as the board is at 100% (at most \(limit) points). With --shape (a title, or \
                #<id> for a shape with none, as a script names one), the view is fitted to those shapes, with what's \
                around them, and with --zoom it's at that zoom, centered on them (or on the whole board), in a picture \
                of \(view) points unless --size says. The board is the one --in or --root names, else the one the \
                shapes are on, else the one the window shows. The result says the file, its size in pixels, the zoom, \
                and the part of the board in it ([[x, y], [width, height]], as a draw's at says where a shape is), and \
                warns when shapes are drawn as skeletons, without their words, or when what's asked for doesn't all fit.
                """,
            params: CaptureParams.self, positionals: ["file"],
            examples: [
                CommandExample("\(canvas) capture board.png", "The whole board the window shows."),
                CommandExample(#"\#(canvas) capture api.png --shape "API""#, "Fitted to the shape titled API, with what's around it."),
                CommandExample(#"\#(canvas) capture api.png --shape "API" --zoom 100"#, "At 100%, centered on API."),
                CommandExample(#"\#(canvas) capture q3.png --in "Q3""#, "The board the subboard titled Q3 holds, the window staying where it is."),
            ]
        ) { params, context throws(AutomationError) in
            try capture(params, in: context)
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
        ) { params, context throws(AutomationError) -> MeasureAnswer in
            // A document is JSON, an object; a script never starts with one.
            if params.script.drop(while: \.isWhitespace).first == "{" {
                do throws(DocumentError) {
                    return .document(try measure(document: params.script, on: params.on, program: canvas, in: context.registry, namesBeyond: context.editor))
                } catch {
                    throw AutomationError(error)
                }
            }
            if params.on != nil {
                throw AutomationError("--on is for a document: a script says where each shape goes itself", reason: "invalid_params",
                                      hint: "leave --on out, or measure the document apply will draw")
            }
            do throws(DrawError) {
                return .script(try measure(script: params.script, program: canvas, in: context.registry, namesBeyond: context.editor))
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

/// What `measure` answers: a script's sizes by line, or a document's by key.
enum MeasureAnswer: Encodable {
    case script(MeasureResult)
    case document(DocumentMeasure)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .script(let result): try result.encode(to: encoder)
        case .document(let result): try result.encode(to: encoder)
        }
    }
}
