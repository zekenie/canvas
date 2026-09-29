import AppKit
@_spi(Host) import Canvas
import Geometry
import Observation
import SwiftUI

/// How the app makes boards: its plugins and each window's content. Set once, before any board
/// opens (`BoardDocument.configuration`).
@MainActor
public struct BoardConfiguration {
    /// The file type boards are saved as: the type the app's Info.plist exports, as `.canvasboard` files (not `.board`, which Apple's Freeform owns).
    public static let typeIdentifier = "com.example.InfiniteCanvas.board"

    public var registry: Registry
    /// A board window's content: the canvas, and whatever goes around it.
    public var content: @MainActor (BoardWindowContent) -> AnyView
    /// How far down over the canvas the content's own views reach on a board, in points (the path
    /// over a subboard's canvas): what the editor's fits leave clear (`CanvasEditor.coveredTop`).
    public var coveredTop: @MainActor (BoardID) -> CGFloat
    /// What the board shown is called, for its window's subtitle: nil on the root, which the title
    /// (the file's name) names. Read observed, so the subtitle follows it as another board is shown
    /// or the board is renamed. CanvasUI doesn't know what names a board; the app says (Composition's
    /// `ShippedPlugins.boardName(of:)`).
    public var boardName: (@MainActor (CanvasEditor) -> String?)?

    public init(registry: Registry, coveredTop: @escaping @MainActor (BoardID) -> CGFloat = { _ in 0 },
                boardName: (@MainActor (CanvasEditor) -> String?)? = nil,
                content: @escaping @MainActor (BoardWindowContent) -> AnyView) {
        self.registry = registry
        self.coveredTop = coveredTop
        self.boardName = boardName
        self.content = content
    }
}

/// What a board window's content works with.
@MainActor
public struct BoardWindowContent {
    public let editor: CanvasEditor
    public let focus: CanvasFocus
    public let view: BoardViewState
}

/// A board window's own state, beside the board: whether the details and the minimap show
/// (remembered per file on this Mac, with the cameras: `BoardViewMemory`), and what the file is
/// called, for the root's crumb on the path.
@MainActor
@Observable
public final class BoardViewState {
    public var showsDetails = true
    public var showsMinimap = true
    /// The file's display name ("Untitled", "Plans"), kept by its window as the title is.
    public var fileName = ""
    public init() {}
}

/// A board as a Mac document: one file per board, autosaved in place, with versions (File ›
/// Revert To). Its editor is the canvas's; any change to the document marks the board edited, while
/// the camera, the selection and the details don't touch it.
///
/// The board's undo is its editor's (`editor.undoHistory`), not an `NSUndoManager`: the document has
/// none, and counts its changes as the history's steps come and go, as NSDocument would from a
/// manager's, but at once. A step that begins marks the board edited; one that comes to nothing,
/// or is undone, takes its change back; one redone puts it back. So undoing to what was saved reads
/// unedited, and undoing past it edited. Text's own undo (a field, a note being typed into) is the
/// board's window's (`BoardWindow`), and isn't counted: what the typing wrote is the board's step.
///
/// A save closes the step under way (`breakStep`), so what's typed after it is a step of its own that
/// the save didn't see, and undo goes back to exactly what was saved. A periodic autosave during a
/// press (a drag), or while a key is held whose repeats are one step (an arrow key's nudges), waits
/// for its release instead of splitting it, and runs once it's over.
///
/// Opening never drops a shape: what the board keeps aside and what it repaired is in `loadReport`,
/// shown when the window first shows; repairs mark the board edited, so the next save keeps them.
/// A file that isn't a board, or comes from a newer app, doesn't open, and says why.
@objc(BoardDocument)
@MainActor
public final class BoardDocument: NSDocument {
    /// Set by the app before any board opens.
    public static var configuration: BoardConfiguration?

    public let editor: CanvasEditor
    /// This board's number while the app runs, from 1: how the command line names it (`canvas
    /// boards`, `--board 2`).
    public let number: Int
    private static var numbered = 0
    public let focus = CanvasFocus()
    public let viewState = BoardViewState()
    /// What opening this board kept aside and repaired; empty for a new board.
    public private(set) var loadReport = LoadReport()
    /// Where each board's view is remembered. Tests put in their own.
    public var viewMemory = BoardViewMemory(defaults: .standard)
    /// The boards whose cameras an earlier session remembered, the one shown last first.
    private var rememberedOrder: [BoardID] = []
    nonisolated let codec: BoardCodec
    private var hasShownLoadReport = false
    /// An autosave gave way to a press: it's scheduled again once the press's step is over.
    private var autosaveWaited = false
    /// An autosave that can wait, waits: a press is under way, or a key is held whose repeats are
    /// part of its step, each with changes.
    private var autosaveWaits: Bool { editor.undoHistory.isPressing || editor.undoHistory.isKeyHolding }
    #if DEBUG
    /// How often an autosave has been scheduled (debug builds, for tests): by NSDocument, or again
    /// once a press an autosave gave way to is over.
    public private(set) var autosavesScheduled = 0
    #endif

    public override init() {
        guard let configuration = Self.configuration else { preconditionFailure("set BoardDocument.configuration before any board opens") }
        editor = CanvasEditor(registry: configuration.registry)
        editor.coveredTop = configuration.coveredTop
        codec = BoardCodec(registry: configuration.registry)
        Self.numbered += 1
        number = Self.numbered
        super.init()
        hasUndoManager = false
        editor.undoHistory.didChange = { [weak self] event in self?.historyDidChange(event) }
    }

    /// Counts the board's changes by its history's steps, as NSDocument counts an undo manager's.
    private func historyDidChange(_ event: UndoEvent) {
        switch event {
        case .began: updateChangeCount(.changeDone)
        case .discarded, .undid: updateChangeCount(.changeUndone)
        case .redid: updateChangeCount(.changeRedone)
        case .closed, .cleared: break
        }
        if event == .closed || event == .discarded, autosaveWaited {
            autosaveWaited = false
            scheduleAutosaving()
        }
    }

    public nonisolated override class var autosavesInPlace: Bool { true }

    public override func scheduleAutosaving() {
        #if DEBUG
        autosavesScheduled += 1
        #endif
        super.scheduleAutosaving()
    }

    /// A new board's shapes: the welcome board, say. The board isn't edited by them.
    public func start(with document: CanvasDocument) {
        editor.replaceDocument(with: document)
    }

    // MARK: Reading and writing

    public override func data(ofType typeName: String) throws -> Data {
        try snapshot(implicitlyCancellable: autosavingIsImplicitlyCancellable)
    }

    /// A save takes the change count it'll mark saved before it writes: the step under way closes
    /// first, so a step that comes to nothing as it closes (a field typed into and back) takes its
    /// change back before the count is taken, and the board reads unedited once saved. (Not for an
    /// autosave that gives way to a press: it won't write.)
    public override func changeCountToken(for saveOperation: NSDocument.SaveOperationType) -> Any {
        if !(autosavingIsImplicitlyCancellable && autosaveWaits) { editor.undoHistory.breakStep() }
        return super.changeCountToken(for: saveOperation)
    }

    /// What a save writes: every board of the file as it is, those it can't show included, with the
    /// step under way closed there, so undo can go back to exactly what was saved. A save that may
    /// give way (a periodic autosave) does, during a press or while a key is held whose repeats are
    /// one step, rather than split its step: it throws `userCancelled`, which NSDocument doesn't
    /// show, and it's scheduled again once the press, or the key, is let go.
    public func snapshot(implicitlyCancellable: Bool) throws -> Data {
        if implicitlyCancellable, autosaveWaits {
            autosaveWaited = true
            throw CocoaError(.userCancelled)
        }
        editor.undoHistory.breakStep()
        return try codec.encode(editor.file)
    }

    /// Deletes what the file keeps aside, as the load report's Delete Hidden Shapes does: the shapes
    /// kept aside, on every board, with the boards they own, and the boards kept, as one undo step,
    /// "Delete Hidden Shapes" (`editor.discardKeptAside`), which edits the file as any step does,
    /// whatever board it took them from. Values kept aside stay.
    public func deleteHiddenShapes() {
        editor.discardKeptAside(shapes: Set(loadReport.keptAside.map(\.id)), boards: Set(loadReport.keptBoards.map(\.key)))
    }

    public nonisolated override func read(from data: Data, ofType typeName: String) throws {
        let loaded: LoadedBoard
        do {
            loaded = try codec.decode(data)
        } catch {
            throw Self.openError(error, earlierVersion: nil)
        }
        // Boards read on the main thread (NSDocument reads concurrently only when asked to).
        MainActor.assumeIsolated { install(loaded) }
    }

    /// As NSDocument reads, but a board that won't open offers its last version, if it has one.
    public nonisolated override func read(from url: URL, ofType typeName: String) throws {
        do {
            try super.read(from: url, ofType: typeName)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadCorruptFileError {
            let versions = NSFileVersion.otherVersionsOfItem(at: url) ?? []
            let newest = versions.max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
            let reason: any Error = (error.userInfo[NSUnderlyingErrorKey] as? BoardReadError).map { $0 as any Error } ?? error
            throw Self.openError(reason, earlierVersion: newest?.url)
        }
    }

    private func install(_ loaded: LoadedBoard) {
        editor.replaceFile(with: loaded.file)
        loadReport = loaded.report
        hasShownLoadReport = false
        if !loaded.report.repairs.isEmpty {
            // After the read is over: a revert clears the change count once it has read.
            Task { @MainActor [weak self] in self?.updateChangeCount(.changeDone) }
        }
    }

    /// Why a board won't open, as the open panel shows it; with a way to open its last version
    /// instead, as an untitled copy, when there is one.
    public nonisolated static func openError(_ error: any Error, earlierVersion: URL?) -> NSError {
        var info: [String: Any] = [
            NSLocalizedFailureReasonErrorKey: (error as? BoardReadError)?.description ?? error.localizedDescription,
            NSUnderlyingErrorKey: error,
        ]
        if let earlierVersion {
            info[NSLocalizedRecoverySuggestionErrorKey] = "An earlier version of it was saved. You can open a copy of that version."
            info[NSLocalizedRecoveryOptionsErrorKey] = ["Open Earlier Version", "Cancel"]
            info[NSRecoveryAttempterErrorKey] = EarlierVersionOpener(url: earlierVersion)
        }
        return NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: info)
    }

    // MARK: Windows

    /// Its window, with the view this Mac remembers of the file: the details and the minimap, each
    /// board's camera, and the board left open, which it opens on, if the file can still show it
    /// (else the root). Opening there puts the file in place on that board (`replaceFile(with:showing:)`),
    /// so it isn't a step back, nor an edit.
    public override func makeWindowControllers() {
        addWindowController(BoardWindowController(board: self))
        if let url = fileURL, let saved = viewMemory.recall(for: url) {
            editor.camera = saved.camera
            editor.rememberedCameras = saved.cameras
            rememberedOrder = saved.recentBoards
            if let board = saved.openBoard, board != editor.board, editor.canShow(board) {
                editor.replaceFile(with: editor.file, showing: board)
            }
            viewState.showsDetails = saved.showsDetails
            viewState.showsMinimap = saved.showsMinimap
        }
    }

    public override func showWindows() {
        super.showWindows()
        showLoadReportIfNeeded()
    }

    public override func close() {
        rememberView()
        super.close()
    }

    /// Remembers, for the next time the file opens, where the camera was left on the boards it can
    /// still show (`editor.boardCameras`): the one shown and those above it, then those shown most
    /// lately, up to `BoardViewMemory.boardLimit`; which board is shown; and whether its details and
    /// minimap show.
    public func rememberView() {
        guard let url = fileURL else { return }
        let all = editor.boardCameras
        var order: [BoardID] = [], seen: Set<BoardID> = []
        let path = editor.boardPath.reversed().filter { !$0.isRoot }
        // Those shown most lately first: left this session, then as an earlier one remembered them.
        let others = editor.boardsLeft + rememberedOrder + all.keys.sorted { $0.description < $1.description }
        for id in path + others where !id.isRoot && all[id] != nil && seen.insert(id).inserted && editor.canShow(id) {
            guard order.count < max(path.count, BoardViewMemory.boardLimit) else { break }
            order.append(id)
        }
        let cameras = Dictionary(uniqueKeysWithValues: order.map { ($0, all[$0]!) })
        viewMemory.remember(BoardViewMemory.View(root: all[.root] ?? Camera(), cameras: cameras, recent: order, board: editor.board,
                                                 showsDetails: viewState.showsDetails, showsMinimap: viewState.showsMinimap), for: url)
    }

    private func showLoadReportIfNeeded() {
        guard !hasShownLoadReport, let summary = loadReport.summary, let window = windowControllers.first?.window else { return }
        hasShownLoadReport = true
        let alert = NSAlert()
        alert.messageText = summary.message
        alert.informativeText = summary.details
        alert.addButton(withTitle: "OK")
        if !loadReport.keptAside.isEmpty || !loadReport.keptBoards.isEmpty { alert.addButton(withTitle: "Delete Hidden Shapes") }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            MainActor.assumeIsolated { self?.deleteHiddenShapes() }
        }
    }
}

extension LoadReport {
    /// What to tell someone opening the board: nil when there's nothing to say.
    public var summary: (message: String, details: String)? {
        guard !isEmpty else { return nil }
        var lines: [String] = []
        if !keptAside.isEmpty {
            let unknown = keptAside.filter { $0.reason == .unknownKind }.map { $0.kind.rawValue }
            let newer = keptAside.filter { $0.isNewer }.map { $0.kind.rawValue }
            let unreadable = keptAside.filter { $0.isUnreadable }
            var parts: [String] = []
            if !unknown.isEmpty { parts.append("\(count(unknown.count)) of a kind this app doesn’t have (\(names(unknown)))") }
            if !newer.isEmpty { parts.append("\(count(newer.count)) from a newer version of the app (\(names(newer)))") }
            if !unreadable.isEmpty { parts.append("\(count(unreadable.count)) that couldn’t be read") }
            lines.append("\(count(keptAside.count).capitalizedFirst) \(keptAside.count == 1 ? "is" : "are") kept as \(keptAside.count == 1 ? "it was" : "they were") but hidden: \(parts.joined(separator: "; ")). Saving keeps \(keptAside.count == 1 ? "it" : "them").")
        }
        if !keptValues.isEmpty {
            let n = keptValues.count
            lines.append("\(n == 1 ? "1 shape holds a property" : "Shapes hold \(n) properties") this app can’t use (\(names(keptValues.map(\.key.rawValue)))), kept as \(n == 1 ? "it was" : "they were"); the \(n == 1 ? "shape shows" : "shapes show") without \(n == 1 ? "it" : "them"). Saving keeps \(n == 1 ? "it" : "them").")
        }
        if !keptBoards.isEmpty {
            let n = keptBoards.count, shapes = keptBoards.reduce(0) { $0 + $1.shapeCount }
            let on = shapes == 0 ? "" : " (\(count(shapes)) on \(n == 1 ? "it" : "them"))"
            lines.append("\(n == 1 ? "1 board" : "\(n) boards") in this file can’t be opened\(on), kept as \(n == 1 ? "it was" : "they were") but hidden. Saving keeps \(n == 1 ? "it" : "them").")
        }
        if !repairs.isEmpty {
            lines.append("\(repairs.count) \(repairs.count == 1 ? "repair was" : "repairs were") made to shapes’ ids, stacking order, metadata or added values. Saving keeps \(repairs.count == 1 ? "it" : "them").")
        }
        let message = !keptAside.isEmpty || !keptBoards.isEmpty ? "Some of this board can’t be shown."
            : !keptValues.isEmpty ? "Some of this board can’t be used here." : "This board was repaired as it opened."
        return (message, lines.joined(separator: "\n\n"))
    }

    private func count(_ n: Int) -> String { n == 1 ? "1 shape" : "\(n) shapes" }
    private func names(_ kinds: [String]) -> String {
        var seen = Set<String>()
        return kinds.filter { seen.insert($0).inserted }.map { $0.isEmpty ? "no kind" : $0 }.joined(separator: ", ")
    }
}

extension LoadReport.KeptShape {
    fileprivate var isNewer: Bool {
        if case .newerVersion = reason { return true }
        return false
    }

    fileprivate var isUnreadable: Bool {
        if case .unreadable = reason { return true }
        return false
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Each file's view, remembered on this Mac by its path, most recent first: the camera on each of
/// its boards, the board left open, and whether the details and the minimap show. Not in the file,
/// so panning or going into a board never marks it edited, and a file opens where this Mac left it.
/// A renamed or moved file opens with the default view.
public struct BoardViewMemory {
    public struct View: Codable, Equatable, Sendable {
        /// The root board's camera.
        public var x: Double
        public var y: Double
        public var zoom: Double
        public var showsDetails: Bool
        public var showsMinimap: Bool
        /// The board left open (a `BoardID`'s description); nil for the root.
        public var board: String?
        /// The camera on each other board shown, by `BoardID` description; nil for none.
        public var boards: [String: Spot]?
        /// Those boards, the one shown last first; nil in a view remembered before it was kept.
        public var recent: [String]?

        /// A camera, as the view keeps it.
        public struct Spot: Codable, Equatable, Sendable {
            public var x: Double
            public var y: Double
            public var zoom: Double
            public init(x: Double, y: Double, zoom: Double) {
                self.x = x
                self.y = y
                self.zoom = zoom
            }
        }

        public init(x: Double, y: Double, zoom: Double, showsDetails: Bool, showsMinimap: Bool = true,
                    board: String? = nil, boards: [String: Spot]? = nil, recent: [String]? = nil) {
            self.x = x
            self.y = y
            self.zoom = zoom
            self.showsDetails = showsDetails
            self.showsMinimap = showsMinimap
            self.board = board
            self.boards = boards
            self.recent = recent
        }

        /// The view of a file shown on `board`, with the root's camera `root` and each other board's
        /// in `cameras` (the root's there is ignored), `recent` saying which were shown last.
        public init(root: Camera, cameras: [BoardID: Camera], recent: [BoardID] = [], board: BoardID, showsDetails: Bool,
                    showsMinimap: Bool) {
            var spots: [String: Spot] = [:]
            for (id, camera) in cameras where !id.isRoot {
                spots[id.description] = Spot(x: camera.origin.x, y: camera.origin.y, zoom: camera.zoom)
            }
            let recent = recent.filter { cameras[$0] != nil && !$0.isRoot }.map(\.description)
            self.init(x: root.origin.x, y: root.origin.y, zoom: root.zoom, showsDetails: showsDetails, showsMinimap: showsMinimap,
                      board: board.isRoot ? nil : board.description, boards: spots.isEmpty ? nil : spots,
                      recent: recent.isEmpty ? nil : recent)
        }

        /// The root's camera.
        public var camera: Camera { Camera(origin: CGPoint(x: x, y: y), zoom: zoom) }
        /// Every other board's camera, as the editor remembers them (`rememberedCameras`); those
        /// whose ids don't read are left out.
        public var cameras: [BoardID: Camera] {
            var cameras: [BoardID: Camera] = [:]
            for (key, spot) in boards ?? [:] {
                guard let id = BoardID(key), !id.isRoot else { continue }
                cameras[id] = Camera(origin: CGPoint(x: spot.x, y: spot.y), zoom: spot.zoom)
            }
            return cameras
        }
        /// The board to open on: nil for the root, and for an id that doesn't read.
        public var openBoard: BoardID? { board.flatMap(BoardID.init) }
        /// The boards of `cameras` in the order they were last shown, the one shown last first, as
        /// far as it was kept.
        public var recentBoards: [BoardID] { (recent ?? []).compactMap(BoardID.init) }

        private enum CodingKeys: String, CodingKey { case x, y, zoom, showsDetails, showsMinimap, board, boards, recent }

        /// A view remembered before there was a minimap shows it, as a new board does; one remembered
        /// before files had boards is the root's.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            x = try container.decode(Double.self, forKey: .x)
            y = try container.decode(Double.self, forKey: .y)
            zoom = try container.decode(Double.self, forKey: .zoom)
            showsDetails = try container.decode(Bool.self, forKey: .showsDetails)
            showsMinimap = try container.decodeIfPresent(Bool.self, forKey: .showsMinimap) ?? true
            board = try container.decodeIfPresent(String.self, forKey: .board)
            boards = try container.decodeIfPresent([String: Spot].self, forKey: .boards)
            recent = try container.decodeIfPresent([String].self, forKey: .recent)
        }
    }

    static let key = "BoardViews"
    /// How many files' views it keeps.
    public static let limit = 100
    /// How many boards' cameras it keeps of a file (more only when the path to the board shown is
    /// deeper): those shown most lately.
    public static let boardLimit = 50

    private struct Entry: Codable {
        var path: String
        var view: View
    }

    let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func recall(for url: URL) -> View? { entries.first { $0.path == url.path }?.view }

    public func remember(_ view: View, for url: URL) {
        var all = entries.filter { $0.path != url.path }
        all.insert(Entry(path: url.path, view: view), at: 0)
        defaults.set(try? JSONEncoder().encode(Array(all.prefix(Self.limit))), forKey: Self.key)
    }

    private var entries: [Entry] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }
}

/// Opens a copy of a board's earlier version, when the board itself won't open.
final class EarlierVersionOpener: NSObject {
    let url: URL
    init(url: URL) { self.url = url }

    @objc override func attemptRecovery(fromError error: any Error, optionIndex recoveryOptionIndex: Int) -> Bool {
        guard recoveryOptionIndex == 0 else { return false }
        let url = url
        return MainActor.assumeIsolated {
            let controller = NSDocumentController.shared
            do {
                let copy = try controller.makeDocument(for: nil, withContentsOf: url, ofType: BoardConfiguration.typeIdentifier)
                controller.addDocument(copy)
                copy.makeWindowControllers()
                copy.showWindows()
                return true
            } catch {
                NSApp.presentError(error)
                return false
            }
        }
    }
}
