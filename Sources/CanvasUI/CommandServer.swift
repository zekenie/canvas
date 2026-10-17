import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import Foundation
import UniformTypeIdentifiers

/// The app's end of the command line (`canvas`): it listens where `canvas` looks (`SocketPath`),
/// tells it what the app is and what it runs (`describe`), and answers each request on the main
/// actor. Three commands are its own, since they're about the app's boards, which only it knows:
/// `status`, `boards` and `new`, which makes a board's file as Save As does and opens it. It's given
/// the rest (`Commands`: the plugins' commands, from the host's slot for them,
/// `registry.hostCommands`), and runs each on the board its request names (`board`), or the one in
/// front, whose editor it changes as anything else does, so the board's window shows each change
/// as it's made. A file with boards inside shapes is worked on where its window is: the board it
/// shows (`editor.board`), which `status` and `boards` name. A board command's result, when it's an
/// object, says which board that was: `board: {id, name, shows, showsPath}`, as `boards` lists it,
/// read in the command's own job as it starts, so nothing switches boards between the two for a
/// command that doesn't wait (`draw`). A command that knows better where inside the file it worked
/// (a query: the board shown as it took up the file) says so in a `board` object of its own, which
/// the server completes with what it knows and the command doesn't (the file's `id` and `name`); a
/// `board` that isn't an object is left alone.
///
/// A command may take its time (one that waits on a language model): each runs as a task of its
/// own, the main actor free while it waits. A request whose client hangs up is answered
/// `cancelled` at once, and its command's task cancelled; and a board command still running when
/// its board's file closes (`BoardDocument.close()`) is answered `board_closed` at once, and let go
/// of the same way, since nothing it did after would reach a window. What a cancelled command
/// returns later is dropped.
@MainActor
public final class CommandServer {
    /// The commands it's given, and how to run one: by name, with its params, on a board's editor
    /// (nil for a command about the app as a whole).
    public struct Commands {
        public var specs: [CommandSpec]
        public var run: @MainActor (_ name: String, _ params: JSON, _ editor: CanvasEditor?) async throws(RPCError) -> JSON

        public init(specs: [CommandSpec],
                    run: @escaping @MainActor (_ name: String, _ params: JSON, _ editor: CanvasEditor?) async throws(RPCError) -> JSON) {
            self.specs = specs
            self.run = run
        }

        /// The commands a plugin gives the host (`registry.hostCommands`: Automation's, every
        /// plugin's command), none where the list has no such plugin.
        @MainActor public init(registry: Registry) {
            let commands = registry.hostCommands
            self.init(specs: commands.specs, run: commands.run)
        }
    }

    public let path: String
    private let commands: Commands
    private let boards: @MainActor () -> [BoardDocument]
    private let frontmost: @MainActor () -> BoardDocument?
    private let show: @MainActor (BoardDocument) -> Void
    /// Which build the app is (`AppInfo.build`): nil for a process that isn't a built app.
    private let build: String?
    /// The files `new` is saving, so a second `new` for one is refused while the first saves.
    private var making: Set<URL> = []
    private var listener: RPCListener?

    /// `boards` and `frontmost` are the app's open boards, and the one whose window is in front;
    /// `show` shows a board `new` made, as the app opens one. `build` is the app's (`AppInfo.build`; the bundle's
    /// `InfiniteCanvasBuild`, which build.sh writes). Tests give their own.
    public init(path: String = SocketPath.resolve(), commands: Commands,
                build: String? = Bundle.main.object(forInfoDictionaryKey: "InfiniteCanvasBuild") as? String,
                boards: @escaping @MainActor () -> [BoardDocument] = { NSDocumentController.shared.documents.compactMap { $0 as? BoardDocument } },
                frontmost: @escaping @MainActor () -> BoardDocument? = { NSApp.orderedDocuments.lazy.compactMap { $0 as? BoardDocument }.first },
                show: @escaping @MainActor (BoardDocument) -> Void = { $0.openWindow() }) {
        let own = Self.ownSpecs.map(\.name)
        precondition(commands.specs.allSatisfy { !own.contains($0.name) }, "a plugin's command takes the name of one of the app's own (the registry refuses it: RPC.reservedCommandNames): \(own)")
        self.path = path
        self.commands = commands
        self.boards = boards
        self.frontmost = frontmost
        self.show = show
        self.build = build
    }

    /// Starts listening. Throws if it can't: another copy of the app is listening there, say.
    public func start() throws(SocketError) {
        guard listener == nil else { return }
        let listener = RPCListener(path: path) { [weak self] request in
            guard let self else { return .failure(RPCError(RPCError.internalError, reason: "stopping", "The app is quitting.")) }
            return await respond(to: request)
        }
        try listener.start()
        self.listener = listener
    }

    /// Stops listening, and removes the socket.
    public func stop() {
        listener?.stop()
        listener = nil
    }

    /// What it answers a request with (what the listener asks it, on the main actor).
    public func respond(to request: RPCRequest) async -> Result<JSON, RPCError> {
        guard request.params == nil || request.params?.objectValue != nil else {
            return .failure(.invalidParams("A request's params are an object, by name."))
        }
        var params = request.params?.objectValue ?? [:]
        switch request.method {
        case RPC.describeMethod:
            return encoded(description)
        case RPC.statusCommand:
            let open = boards()
            var status: [String: JSON] = ["app": .string(info.name), "version": .string(info.version), "pid": .number(Double(info.pid)),
                                          "protocol": .number(Double(RPC.protocolVersion)), "socket": .string(path),
                                          "boards": .number(Double(open.count))]
            if let build { status["build"] = .string(build) }
            if let front = frontmost() {
                status["frontmost"] = .number(Double(front.number))
                status["frontmostShows"] = .string(front.editor.board.description)
            }
            return .success(.object(status))
        case RPC.boardsCommand:
            let front = frontmost()
            return .success(.array(boards().map { .object(Self.listed($0, frontmost: front)) }))
        case RPC.newCommand:
            return await newBoard(params)
        default:
            guard let spec = commands.specs.first(where: { $0.name == request.method }) else {
                return .failure(RPCError(RPCError.methodNotFound, reason: "unknown_command", "There's no command \(request.method).",
                                         hint: "`\(RPC.commandName) help` lists the commands."))
            }
            let reference = params.removeValue(forKey: RPC.boardParam)
            var target: BoardDocument?
            switch spec.scope {
            case .board:
                // A command that works with no board too runs on none when none is named, in front or the only one.
                if reference == nil, spec.boardOptional == true, frontmost() == nil, boards().count != 1 { break }
                switch board(reference) {
                case .success(let board): target = board
                case .failure(let error): return .failure(error)
                }
            case .app:
                guard reference == nil else { return .failure(.invalidParams("\(spec.name) is about the app, not a board: it takes no board.")) }
            }
            let (outcome, worked) = await run(spec.name, .object(params), on: target)
            switch outcome {
            case .success(let result):
                guard let worked, case .object(var object) = result else { return .success(result) }
                switch object[RPC.boardParam] {
                case nil: object[RPC.boardParam] = .object(worked)
                case .object(let own)?: object[RPC.boardParam] = .object(worked.merging(own) { _, own in own })
                default: return .success(result)
                }
                return .success(.object(object))
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    // MARK: Running a command

    /// Runs a command in a task of its own, kept against its board (`running`), and answers as it
    /// finishes, or at once, as its request is cancelled (`cancelled`) or its board closes
    /// (`board_closed`), whichever comes first; what comes after the answer is dropped. With the
    /// outcome, which board it worked on, as `boards` lists it (the command can't know), read in the
    /// command's job just before it runs: a command that doesn't wait runs in that job, so no
    /// switch of board comes between the two.
    private func run(_ name: String, _ params: JSON, on board: BoardDocument?) async -> (Result<JSON, RPCError>, [String: JSON]?) {
        let command = RunningCommand(board: board)
        let editor = board?.editor, commands = commands
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                command.continuation = continuation
                Self.running.append(command)
                command.task = Task { @MainActor in
                    // Its board closed before it started: it doesn't run at all.
                    guard !Task.isCancelled else { return }
                    let worked = command.board.map(Self.shown)
                    let outcome: Result<JSON, RPCError>
                    do throws(RPCError) {
                        outcome = .success(try await commands.run(name, params, editor))
                    } catch {
                        outcome = .failure(error)
                    }
                    command.answer(outcome, worked)
                }
            }
        } onCancel: {
            Task { @MainActor in command.stop(answering: Self.cancelled) }
        }
    }

    /// The commands running, each kept against its board (none for an app command) until it's
    /// answered.
    private static var running: [RunningCommand] = []

    /// A board's file is closing (`BoardDocument.close()`): its commands still running are answered
    /// `board_closed` now, and their tasks cancelled.
    static func boardWillClose(_ board: BoardDocument) {
        for command in running where command.board === board { command.stop(answering: boardClosed) }
    }

    static let cancelled = RPCError(RPCError.failed, reason: "cancelled", "The request was cancelled before the command finished.")
    static let boardClosed = RPCError(RPCError.failed, reason: "board_closed", "The board was closed before the command finished.",
                                      hint: "Open it again, and run the command again.")

    /// A command on its way: the task running it, and the request waiting for its answer.
    @MainActor
    private final class RunningCommand {
        weak var board: BoardDocument?
        var task: Task<Void, Never>?
        var continuation: CheckedContinuation<(Result<JSON, RPCError>, [String: JSON]?), Never>?

        init(board: BoardDocument?) {
            self.board = board
        }

        /// Answers the request, with the board it worked on, unless it has been answered already.
        func answer(_ outcome: Result<JSON, RPCError>, _ worked: [String: JSON]?) {
            guard let continuation else { return }
            self.continuation = nil
            task = nil
            CommandServer.running.removeAll { $0 === self }
            continuation.resume(returning: (outcome, worked))
        }

        /// Answers the request with `error` now, and cancels the task, which stops at its next check.
        func stop(answering error: RPCError) {
            task?.cancel()
            answer(.failure(error), nil)
        }
    }

    // MARK: Describing the app

    private var info: AppInfo {
        let bundle = Bundle.main
        return AppInfo(name: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Infinite Canvas",
                       version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                       pid: Int(ProcessInfo.processInfo.processIdentifier),
                       path: bundle.bundleURL.pathExtension == "app" ? bundle.bundlePath : nil, build: build)
    }

    private var description: AppDescription {
        AppDescription(app: info, commands: Self.ownSpecs + commands.specs)
    }

    /// The server's own commands: about the app, and its boards.
    static let ownSpecs = [
        CommandSpec(name: RPC.statusCommand, summary: "Say whether the app is running, how many boards it has open, and which is in front.",
                    discussion: "frontmostShows is the board inside the file in front that its window shows (\"root\", or the id of the shape that owns it): where a board command works.\n\nbuild is which build the app is (the commit it was built from, and a hash of the changes if the tree had any): the skills that came with it say the same, and `canvas install` copies the app's again when they don't.",
                    scope: .app,
                    params: ["type": "object", "properties": [:], "additionalProperties": false],
                    examples: [CommandExample("\(RPC.commandName) status", "The app's version, its process, and its boards.")]),
        CommandSpec(name: RPC.boardsCommand, summary: "List the open boards: each one's id, name, file, which is in front, and what its window shows.",
                    discussion: "A board command works on the board in front unless --board names another: by its id here (which lasts while the app runs), its file, or its name. A file can hold boards inside its shapes; a command works on the one its window shows: shows (\"root\", or the id of the shape that owns it) and showsPath, the boards from the root down to it. shapes counts that board's shapes, and fileShapes the file's, on every board. view is the room its window has for a board fit into it, [width, height] in points (the canvas, less the margin a fit leaves), whichever board it shows: what a tool that lays a board out shapes it for; left out while the window has no size.",
                    scope: .app, params: ["type": "object", "properties": [:], "additionalProperties": false],
                    examples: [CommandExample("\(RPC.commandName) boards", "Every open board.")]),
        CommandSpec(name: RPC.newCommand, summary: "Make a new, empty board's file, open it, and say it as boards lists it.",
                    discussion: "Its id is the board's --board. The file gets .\(BoardConfiguration.fileExtension) unless it ends in it (Sprint 3.2 is Sprint 3.2.\(BoardConfiguration.fileExtension)). A file that's there already, or open, another type's file (.txt), and a folder that isn't there are refused.",
                    scope: .app,
                    params: ["type": "object",
                             "properties": ["path": ["type": "string", "description": "The board's file.", "x-value-name": "file", "x-path": true]],
                             "required": ["path"], "additionalProperties": false],
                    positionals: ["path"],
                    examples: [CommandExample("\(RPC.commandName) new ~/Boards/Plans.\(BoardConfiguration.fileExtension)", "Make Plans, and open it.")]),
    ]

    // MARK: Boards

    /// A board as `boards` lists it: what a board command's result names it by (`shown`), which is
    /// in front, whether it's edited, how many shapes the board shown holds and how many the file
    /// does, on every board, its file, and the room its window has for a board fit into it (`view`).
    private static func listed(_ board: BoardDocument, frontmost: BoardDocument?) -> [String: JSON] {
        var entry = shown(board)
        entry["frontmost"] = .bool(board === frontmost)
        entry["edited"] = .bool(board.isDocumentEdited)
        entry["shapes"] = .number(Double(board.editor.document.shapes.count))
        entry["fileShapes"] = .number(Double(board.editor.file.shapeCount))
        if let url = board.fileURL { entry["path"] = .string(url.path) }
        if let room = fitRoom(of: board.editor) { entry["view"] = .array([.number(Double(room.width)), .number(Double(room.height))]) }
        return entry
    }

    /// The room a window has for a board fit into it, in view points: what a first visit fits the
    /// root board's shapes into, at 100% at most (the view, `CanvasEditor.firstVisitInset` in from
    /// its edges). It is the window's, whichever board of the file it shows now: a board inside a
    /// shape has a little less, under what the host puts over it (`unobscuredViewport`), and a tool
    /// that asks twice must be told the same. Nil while the view has no size, or none to spare.
    static func fitRoom(of editor: CanvasEditor) -> CGSize? {
        let room = CGRect(origin: .zero, size: editor.viewportSize).insetBy(dx: CanvasEditor.firstVisitInset, dy: CanvasEditor.firstVisitInset)
        guard !room.isNull, room.width >= 1, room.height >= 1 else { return nil }
        return room.size
    }

    /// A file and the board inside it its window shows, as `boards` lists them and a board
    /// command's result names them: the file's id and name, `shows` ("root", or the id of the shape
    /// that owns the board) and `showsPath`, the boards from the root down to it.
    private static func shown(_ board: BoardDocument) -> [String: JSON] {
        let editor = board.editor
        return ["id": .number(Double(board.number)), "name": .string(board.displayName ?? "untitled"),
                "shows": .string(editor.board.description), "showsPath": .array(editor.boardPath.map { .string($0.description) })]
    }

    /// The board a request names: by its number, its file, or its name. With none named, the board
    /// in front, or the only one open.
    private func board(_ reference: JSON?) -> Result<BoardDocument, RPCError> {
        let open = boards()
        let listing = open.map { "\($0.number) (\($0.displayName ?? "untitled"))" }.joined(separator: ", ")
        guard let reference else {
            if let front = frontmost() { return .success(front) }
            if open.count == 1 { return .success(open[0]) }
            return .failure(open.isEmpty
                ? .failed("No board is open.", reason: "no_board", hint: "Make one: \(RPC.commandName) \(RPC.newCommand) <file>, or open one in Infinite Canvas.")
                : .failed("\(open.count) boards are open, and none is in front.", reason: "ambiguous_board",
                          hint: "Name one with --board: \(listing)."))
        }
        guard let text = reference.stringValue ?? reference.intValue.map(String.init) else {
            return .failure(.invalidParams("A board is named by its id, its file or its name."))
        }
        if let board = open.first(where: { String($0.number) == text }) { return .success(board) }
        if text.hasPrefix("/") {
            let file = URL(fileURLWithPath: text).standardizedFileURL.resolvingSymlinksInPath()
            if let board = open.first(where: { $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == file }) { return .success(board) }
            return .failure(.failed("\(text) isn't open.", reason: "unknown_board", hint: "Open it in Infinite Canvas: open \(Self.quoted(text))."))
        }
        let named = open.filter { $0.displayName == text }
        if named.count == 1 { return .success(named[0]) }
        if named.count > 1 {
            return .failure(.failed("\(named.count) open boards are called \(text).", reason: "ambiguous_board",
                                    hint: "Name one by its id: \(listing)."))
        }
        return .failure(.failed("No open board is \(text).", reason: "unknown_board",
                                hint: open.isEmpty ? "No board is open." : "The open boards: \(listing)."))
    }

    // MARK: A new board

    /// `new`: a new board's file at `path` (whole, as `canvas` sends it), made as Save As makes one
    /// (`BoardDocument.newFile(at:)`), never written here, then shown as the app opens a board, and
    /// said as `boards` lists it. A file gets the boards' extension unless it ends in a known type's,
    /// as the Save panel adds one (`Sprint 3.2` is `Sprint 3.2.canvasboard`), which is refused (a
    /// `.txt`), as are a file that's there already, or that a board open is or a `new` is saving, and
    /// a folder that isn't there.
    private func newBoard(_ params: [String: JSON]) async -> Result<JSON, RPCError> {
        let new = RPC.newCommand, ending = BoardConfiguration.fileExtension
        guard let written = params["path"]?.stringValue, params.keys.allSatisfy({ $0 == "path" }) else {
            return .failure(.invalidParams("\(new) takes path, the board's file, and nothing else."))
        }
        guard written.hasPrefix("/") else {
            return .failure(.invalidParams("A board's file is named by its whole path, from /, and \(written.isEmpty ? "none was given" : "\(written) isn't one")."))
        }
        let given = URL(fileURLWithPath: written).standardizedFileURL
        var url = given
        if given.pathExtension.lowercased() != ending {
            let other = given.pathExtension
            if !other.isEmpty, let type = UTType(filenameExtension: other), !type.isDynamic {
                return .failure(.invalidParams("A board's file ends in .\(ending), and \(given.lastPathComponent) is a .\(other) file.",
                                               hint: "\(RPC.commandName) \(new) \(Self.quoted(given.deletingPathExtension().appendingPathExtension(ending).path))"))
            }
            var name = given.lastPathComponent
            while name.hasSuffix(".") { name.removeLast() }
            url = given.deletingLastPathComponent().appendingPathComponent("\(name).\(ending)")
        }
        let file = url.resolvingSymlinksInPath()
        if let board = boards().first(where: { $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == file }) {
            return .failure(.failed("\(url.path) is open already, as board \(board.number).", reason: "file_exists",
                                    hint: "Name it with --board \(board.number), or make another file."))
        }
        guard !making.contains(file) else {
            return .failure(.failed("\(url.path) is being made already.", reason: "file_exists", hint: "Wait for it, then name it with --board."))
        }
        // A folder as written too: `new plans` beside a folder called plans is a mistake, not plans.canvasboard.
        if url != given, Self.isFolder(given) {
            return .failure(.failed("\(given.path) is a folder.", reason: "file_exists", hint: "Name a file inside it, or another file."))
        }
        if FileManager.default.fileExists(atPath: url.path) {
            return .failure(.failed("\(url.path) is there already\(Self.isFolder(url) ? ", a folder" : "").", reason: "file_exists",
                                    hint: Self.isFolder(url) ? "Name a file inside it, or another file." : "Open it in Infinite Canvas: open \(Self.quoted(url.path)). Or make another file."))
        }
        let folder = url.deletingLastPathComponent()
        guard Self.isFolder(folder) else {
            return .failure(.failed("There's no folder \(folder.path).", reason: "no_folder", hint: "Make it first: mkdir -p \(Self.quoted(folder.path))"))
        }
        making.insert(file)
        defer { making.remove(file) }
        let board: BoardDocument
        do {
            board = try await BoardDocument.newFile(at: url)
        } catch {
            return .failure(.failed("\(url.path) couldn't be saved: \(error.localizedDescription)", reason: "cannot_save"))
        }
        show(board)
        return .success(.object(Self.listed(board, frontmost: frontmost())))
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    private static func quoted(_ path: String) -> String {
        path.contains(where: { $0.isWhitespace || "'\"$`\\".contains($0) }) ? "'\(path.replacingOccurrences(of: "'", with: #"'\''"#))'" : path
    }

    private func encoded(_ value: some Encodable) -> Result<JSON, RPCError> {
        do {
            return .success(try JSON(encoding: value))
        } catch {
            return .failure(RPCError(RPCError.internalError, reason: "internal", "\(error)"))
        }
    }
}
