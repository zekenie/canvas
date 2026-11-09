import AppKit
import Canvas
import Draw

// What turns what another app put on the pasteboard into shapes: a plugin's reader (`registrar.pasteReader`) reads the text or
// the files on it, and says what to put down, either shapes (a `CanvasFile`, put down as the app's own are) or a draw program
// (a `DrawPut`, which Draw puts down by names, beside the selection or on a point, as one step).

/// What a pasteboard holds besides this app's shapes, read once a change of it.
public struct PasteContent: Sendable {
    /// The most text read, from the pasteboard or a file, in bytes: more is none.
    public static let textLimit = 2_000_000
    /// The most files read.
    public static let fileLimit = 20

    /// A local file on the pasteboard.
    public struct File: Sendable {
        public let url: URL
        /// Its name, with its extension.
        public let name: String
        private let contents: FileText

        /// Its text, when it is a small file that reads as UTF-8: read when first asked, once, since most pastes never ask.
        public var text: String? { contents.text }

        public init(url: URL, text: String?) {
            self.url = url
            name = url.lastPathComponent
            contents = FileText(text)
        }

        /// A file whose text is read when asked.
        init(url: URL, reading read: @escaping @Sendable () -> String?) {
            self.url = url
            name = url.lastPathComponent
            contents = FileText(reading: read)
        }

        public var fileExtension: String { url.pathExtension.lowercased() }
    }

    /// The pasteboard's text (`public.utf8-plain-text`), unless it holds files, whose names Finder also puts there as text:
    /// files come before text. Nil for none, or more than `textLimit`.
    public let text: String?
    /// Its local files, in order, at most `fileLimit`.
    public let files: [File]

    public init(text: String? = nil, files: [File] = []) {
        self.text = files.isEmpty ? text : nil
        self.files = files
    }

    /// The text a plain reader makes of it: the text, else the first file's, if it isn't blank.
    public var plainText: String? {
        let found = text ?? files.lazy.compactMap(\.text).first
        guard let found, !found.allSatisfy(\.isWhitespace) else { return nil }
        return found
    }

    /// What `pasteboard` holds now.
    static func reading(_ pasteboard: NSPasteboard) -> PasteContent {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var files: [File] = []
        for url in urls.prefix(fileLimit) {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let size = values?.fileSize, size <= textLimit {
                files.append(File(url: url, reading: { try? String(contentsOf: url, encoding: .utf8) }))
            } else {
                files.append(File(url: url, text: nil))
            }
        }
        var text = pasteboard.string(forType: .string)
        if let found = text, found.isEmpty || found.utf8.count > textLimit { text = nil }
        return PasteContent(text: text, files: files)
    }
}

/// A file's text, read the first time it is asked for (a copied folder of large files costs nothing to a paste that no reader
/// reads files for).
private final class FileText: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String??
    private let read: (@Sendable () -> String?)?

    init(_ text: String?) {
        value = .some(text)
        read = nil
    }

    init(reading read: @escaping @Sendable () -> String?) {
        self.read = read
    }

    var text: String? {
        lock.lock()
        defer { lock.unlock() }
        if let value { return value }
        let found = read?()
        value = .some(found)
        return found
    }
}

/// What a reader makes of what it read.
public enum PasteResult {
    /// Shapes to put down as the app's own are (a `CanvasFile`: its root's shapes, back to front, with the boards they own and
    /// what containers among them hold): new shapes, never copies, centered in the view (on the pointer for Paste at Pointer, on
    /// the click for a context menu's Paste), settled where they land, selected, in one Paste step.
    case shapes(CanvasFile)
    /// A draw program for Draw to put down: its names found nearest first, beside the selection (centered for a click or the
    /// pointer), selected, in one step, "Paste" and the reader's name.
    case put(DrawPut)

    var isEmpty: Bool {
        switch self {
        case .shapes(let file): file.root.shapes.isEmpty
        case .put(let put): put.isEmpty
        }
    }
}

/// What reads the pasteboard besides this app's shapes (`registrar.pasteReader`): asked in plugin order, after this app's
/// shapes, and the first that reads something is the paste. A kit switches them: a reader whose plugin's kit is off in the file is
/// never asked.
public enum PasteReaders {}

extension PasteReaders: ExtensionPoint, KitSwitched {
    public typealias Contribution = PasteReader
    public static var owner: PluginID { .clipboard }
    public static func summary(of reader: PasteReader, for _: ShapeTarget) -> String { "paste reader \(reader.name)" }
}

/// A reader of the pasteboard (`registrar.pasteReader`).
public struct PasteReader {
    /// Who asks it.
    public enum Role: Sendable {
        /// ⌘V's, ⇧⌘V's and the context menu's Paste: a reader that recognizes what it reads, so it reads nothing else.
        case recognizing
        /// ⌥⇧⌘V's, Paste as Note: a reader that takes whatever is there.
        case plain
    }

    /// What it reads, for the registry's report ("emoji", "SQL"), and its step ("Paste SQL").
    public let name: String
    public let role: Role
    /// Whether it may read this, cheaply (menus ask it); nil to be asked to read, once a change of the pasteboard.
    let sniff: (@MainActor (PasteContent) -> Bool)?
    /// What it makes of it, or nil for content that isn't its after all.
    let read: @MainActor (PasteContent, CanvasEditor) -> PasteResult?
    /// What of the file its reading reads (the SQL reader's: the names of the file's enums, which it measures a column by), nil for
    /// none: a reading is kept until the pasteboard changes, or this does.
    var readsOfFile: (@MainActor (CanvasEditor) -> AnyHashable)? = nil
}

extension PluginRegistrar {
    /// Reads text another app put on the pasteboard into shapes: `read` is handed the text and the editor, and
    /// gives back what to put down as a file (its root's shapes, back to front, with the boards they own and
    /// what containers among them hold), anywhere, or nil for text it doesn't read. ⌘V puts its shapes down
    /// as it puts down this app's own, as new shapes, never copies: centered in the view (on the pointer for
    /// Paste at Pointer, on the click for a context menu's Paste), settled where they land, selected, in one
    /// Paste step. Asked as the pasteboard changes, so keep it cheap; only when the pasteboard holds none of this
    /// app's shapes, after the readers before it in plugin order, and never while the plugin's kit is off.
    public mutating func pasteReader(_ name: String, _ read: @escaping @MainActor (_ text: String, _ editor: CanvasEditor) -> CanvasFile?) {
        contribute(PasteReader(name: name, role: .recognizing, sniff: nil) { content, editor in
            content.text.flatMap { read($0, editor) }.map(PasteResult.shapes)
        }, to: PasteReaders.self)
    }

    /// Reads the pasteboard into a draw program Draw puts down: `sniff` says cheaply whether `read` may read what is there (menus
    /// ask it), `read` gives the program (`DrawPut`: shapes by kind and title, the rows to lay them out
    /// in) or nil for content that isn't its after all. A `.recognizing` reader (the default) is ⌘V's, ⇧⌘V's and the context
    /// menu's Paste, asked in plugin order after this app's shapes; a `.plain` one is ⌥⇧⌘V's, Paste as Note, and no other's. The put
    /// lands beside the selection (centered on a click or the pointer), finds the shapes the file has by kind and title, the nearest
    /// first, selected, in one step "Paste" and the reader's name. Never asked while the plugin's kit is off.
    ///
    /// `readsOfFile`: what of the file `read` reads, for a reader whose program says something of the file as well as the pasteboard
    /// (the SQL reader measures a column typed as one of the file's enums as its pill): its reading is read again once that changes.
    public mutating func pasteReader(_ name: String, role: PasteReader.Role = .recognizing,
                                     sniff: @escaping @MainActor (PasteContent) -> Bool,
                                     readsOfFile: (@MainActor (CanvasEditor) -> AnyHashable)? = nil,
                                     read: @escaping @MainActor (_ content: PasteContent, _ editor: CanvasEditor) -> DrawPut?) {
        contribute(PasteReader(name: name, role: role, sniff: sniff, read: { content, editor in read(content, editor).map(PasteResult.put) },
                               readsOfFile: readsOfFile),
                   to: PasteReaders.self)
    }

    /// As the reader above, for one that may give shapes (`PasteResult.shapes`) or a program (`PasteResult.put`).
    public mutating func pasteReading(_ name: String, role: PasteReader.Role = .recognizing,
                                      sniff: @escaping @MainActor (PasteContent) -> Bool,
                                      read: @escaping @MainActor (_ content: PasteContent, _ editor: CanvasEditor) -> PasteResult?) {
        contribute(PasteReader(name: name, role: role, sniff: sniff, read: read), to: PasteReaders.self)
    }
}
