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

    public init(registry: Registry, content: @escaping @MainActor (BoardWindowContent) -> AnyView) {
        self.registry = registry
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

/// A board window's own state, beside the board: whether the details and the minimap show.
/// Remembered per file on this Mac, with the camera (`BoardViewMemory`).
@MainActor
@Observable
public final class BoardViewState {
    public var showsDetails = true
    public var showsMinimap = true
    public init() {}
}

/// A board as a Mac document: one file per board, autosaved in place, with versions (File ›
/// Revert To). Its editor is the canvas's; any transaction that changes the document marks the
/// board edited, while the camera, the selection and the details don't touch it.
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
    public let focus = CanvasFocus()
    public let viewState = BoardViewState()
    /// What opening this board kept aside and repaired; empty for a new board.
    public private(set) var loadReport = LoadReport()
    /// Where each board's view is remembered. Tests put in their own.
    public var viewMemory = BoardViewMemory(defaults: .standard)
    nonisolated let codec: BoardCodec
    private var hasShownLoadReport = false

    public override init() {
        guard let configuration = Self.configuration else { preconditionFailure("set BoardDocument.configuration before any board opens") }
        editor = CanvasEditor(registry: configuration.registry)
        codec = BoardCodec(registry: configuration.registry)
        super.init()
        editor.didCommitTransaction = { [weak self] _ in self?.updateChangeCount(.changeDone) }
    }

    public nonisolated override class var autosavesInPlace: Bool { true }

    /// A new board's shapes: the welcome board, say. The board isn't edited by them.
    public func start(with document: CanvasDocument) {
        editor.replaceDocument(with: document)
    }

    // MARK: Reading and writing

    public override func data(ofType typeName: String) throws -> Data {
        try codec.encode(editor.document)
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
        editor.replaceDocument(with: loaded.document)
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

    public override func makeWindowControllers() {
        addWindowController(BoardWindowController(board: self))
        if let url = fileURL, let saved = viewMemory.recall(for: url) {
            editor.camera = Camera(origin: CGPoint(x: saved.x, y: saved.y), zoom: saved.zoom)
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

    /// Remembers where this board's camera is and whether its details and minimap show, for the
    /// next time it opens.
    public func rememberView() {
        guard let url = fileURL else { return }
        let camera = editor.camera
        viewMemory.remember(BoardViewMemory.View(x: camera.origin.x, y: camera.origin.y, zoom: camera.zoom,
                                                 showsDetails: viewState.showsDetails, showsMinimap: viewState.showsMinimap), for: url)
    }

    private func showLoadReportIfNeeded() {
        guard !hasShownLoadReport, let summary = loadReport.summary, let window = windowControllers.first?.window else { return }
        hasShownLoadReport = true
        let alert = NSAlert()
        alert.messageText = summary.message
        alert.informativeText = summary.details
        alert.addButton(withTitle: "OK")
        let keptAside = Set(loadReport.keptAside.map(\.id))
        if !keptAside.isEmpty { alert.addButton(withTitle: "Delete Hidden Shapes") }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            MainActor.assumeIsolated { _ = self?.editor.transact { $0.delete(keptAside) } }
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
        if !repairs.isEmpty {
            lines.append("\(repairs.count) \(repairs.count == 1 ? "repair was" : "repairs were") made to shapes’ ids or stacking order. Saving keeps \(repairs.count == 1 ? "it" : "them").")
        }
        let message = keptAside.isEmpty ? "This board was repaired as it opened." : "Some of this board can’t be shown."
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

/// Each board's view, remembered on this Mac by its file's path, most recent first: the camera and
/// whether the details and the minimap show. Not in the board, so panning never marks it edited,
/// and a board opens where this Mac left it. A renamed or moved board opens with the default view.
public struct BoardViewMemory {
    public struct View: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var zoom: Double
        public var showsDetails: Bool
        public var showsMinimap: Bool
        public init(x: Double, y: Double, zoom: Double, showsDetails: Bool, showsMinimap: Bool = true) {
            self.x = x
            self.y = y
            self.zoom = zoom
            self.showsDetails = showsDetails
            self.showsMinimap = showsMinimap
        }

        private enum CodingKeys: String, CodingKey { case x, y, zoom, showsDetails, showsMinimap }

        /// A view remembered before there was a minimap shows it, as a new board does.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            x = try container.decode(Double.self, forKey: .x)
            y = try container.decode(Double.self, forKey: .y)
            zoom = try container.decode(Double.self, forKey: .zoom)
            showsDetails = try container.decode(Bool.self, forKey: .showsDetails)
            showsMinimap = try container.decodeIfPresent(Bool.self, forKey: .showsMinimap) ?? true
        }
    }

    static let key = "BoardViews"
    /// How many boards' views it keeps.
    public static let limit = 100

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
