import AppKit
import Canvas
import CanvasRPC
import Foundation

/// The app's end of the command line (`canvas`): it listens where `canvas` looks (`SocketPath`),
/// tells it what the app is and what it runs (`describe`), and answers each request on the main
/// actor. Two commands are its own, since they're about the app's boards, which only it knows:
/// `status` and `boards`. It's given the rest (`Commands`: the plugins' commands, from Composition),
/// and runs each on the board its request names (`board`), or the one in front, whose editor it
/// changes as anything else does, so the board's window shows each change as it's made.
@MainActor
public final class CommandServer {
    /// The commands it's given, and how to run one: by name, with its params, on a board's editor
    /// (nil for a command about the app as a whole).
    public struct Commands {
        public var specs: [CommandSpec]
        public var run: @MainActor (_ name: String, _ params: JSON, _ editor: CanvasEditor?) throws(RPCError) -> JSON

        public init(specs: [CommandSpec], run: @escaping @MainActor (_ name: String, _ params: JSON, _ editor: CanvasEditor?) throws(RPCError) -> JSON) {
            self.specs = specs
            self.run = run
        }
    }

    public let path: String
    private let commands: Commands
    private let boards: @MainActor () -> [BoardDocument]
    private let frontmost: @MainActor () -> BoardDocument?
    private var listener: RPCListener?

    /// `boards` and `frontmost` are the app's open boards, and the one whose window is in front;
    /// tests give their own.
    public init(path: String = SocketPath.resolve(), commands: Commands,
                boards: @escaping @MainActor () -> [BoardDocument] = { NSDocumentController.shared.documents.compactMap { $0 as? BoardDocument } },
                frontmost: @escaping @MainActor () -> BoardDocument? = { NSApp.orderedDocuments.lazy.compactMap { $0 as? BoardDocument }.first }) {
        let own = Self.ownSpecs.map(\.name)
        precondition(commands.specs.allSatisfy { !own.contains($0.name) }, "a plugin's command takes the name of one of the app's own (the registry refuses it: RPC.reservedCommandNames): \(own)")
        self.path = path
        self.commands = commands
        self.boards = boards
        self.frontmost = frontmost
    }

    /// Starts listening. Throws if it can't: another copy of the app is listening there, say.
    public func start() throws(SocketError) {
        guard listener == nil else { return }
        let listener = RPCListener(path: path) { [weak self] request in
            self?.respond(to: request) ?? .failure(RPCError(RPCError.internalError, reason: "stopping", "The app is quitting."))
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
    public func respond(to request: RPCRequest) -> Result<JSON, RPCError> {
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
            if let front = frontmost() { status["frontmost"] = .number(Double(front.number)) }
            return .success(.object(status))
        case RPC.boardsCommand:
            let front = frontmost()
            return .success(.array(boards().map { board in
                var entry: [String: JSON] = ["id": .number(Double(board.number)), "name": .string(board.displayName),
                                             "frontmost": .bool(board === front), "edited": .bool(board.isDocumentEdited),
                                             "shapes": .number(Double(board.editor.document.shapes.count))]
                if let url = board.fileURL { entry["path"] = .string(url.path) }
                return .object(entry)
            }))
        default:
            guard let spec = commands.specs.first(where: { $0.name == request.method }) else {
                return .failure(RPCError(RPCError.methodNotFound, reason: "unknown_command", "There's no command \(request.method).",
                                         hint: "`\(RPC.commandName) help` lists the commands."))
            }
            let reference = params.removeValue(forKey: RPC.boardParam)
            var editor: CanvasEditor?
            switch spec.scope {
            case .board:
                switch board(reference) {
                case .success(let board): editor = board.editor
                case .failure(let error): return .failure(error)
                }
            case .app:
                guard reference == nil else { return .failure(.invalidParams("\(spec.name) is about the app, not a board: it takes no board.")) }
            }
            do {
                return .success(try commands.run(spec.name, .object(params), editor))
            } catch {
                return .failure(error)
            }
        }
    }

    // MARK: Describing the app

    private var info: AppInfo {
        let bundle = Bundle.main
        return AppInfo(name: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Infinite Canvas",
                       version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                       pid: Int(ProcessInfo.processInfo.processIdentifier),
                       path: bundle.bundleURL.pathExtension == "app" ? bundle.bundlePath : nil)
    }

    private var description: AppDescription {
        AppDescription(app: info, commands: Self.ownSpecs + commands.specs)
    }

    /// The server's own commands: about the app, and its boards.
    static let ownSpecs = [
        CommandSpec(name: RPC.statusCommand, summary: "Say whether the app is running, and how many boards it has open.", scope: .app,
                    params: ["type": "object", "properties": [:], "additionalProperties": false],
                    examples: [CommandExample("\(RPC.commandName) status", "The app's version, its process, and its boards.")]),
        CommandSpec(name: RPC.boardsCommand, summary: "List the open boards: each one's id, name, file, and which is in front.",
                    discussion: "A board command works on the board in front unless --board names another: by its id here (which lasts while the app runs), its file, or its name.",
                    scope: .app, params: ["type": "object", "properties": [:], "additionalProperties": false],
                    examples: [CommandExample("\(RPC.commandName) boards", "Every open board.")]),
    ]

    // MARK: Boards

    /// The board a request names: by its number, its file, or its name. With none named, the board
    /// in front, or the only one open.
    private func board(_ reference: JSON?) -> Result<BoardDocument, RPCError> {
        let open = boards()
        let listing = open.map { "\($0.number) (\($0.displayName ?? "untitled"))" }.joined(separator: ", ")
        guard let reference else {
            if let front = frontmost() { return .success(front) }
            if open.count == 1 { return .success(open[0]) }
            return .failure(open.isEmpty
                ? .failed("No board is open.", reason: "no_board", hint: "Open or make one in Infinite Canvas.")
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
