import AppKit
import Canvas
import CanvasUI
import Composition
import SwiftUI

/// A document app: each board is a file (`BoardDocument`), in its own window, with the shipped
/// plugins. AppKit runs it, so the menus and Open Recent are AppKit's; each window's content is
/// SwiftUI.
@main
@MainActor
enum InfiniteCanvasApp {
    static let delegate = AppDelegate()
    /// Where the command line (`canvas`) reaches the app.
    static var commandServer: CommandServer?

    static func main() {
        let registry: Registry
        do {
            registry = try ShippedPlugins.registry(model: ShippedPlugins.anthropicModel)
            BoardDocument.configuration = BoardConfiguration(registry: registry) { AnyView(ContentView(board: $0)) }
            delegate.settings = SettingsWindow(registry: registry)
        } catch {
            fatalError("The shipped plugins don't register: \(error)")   // CompositionTests catches this first
        }
        let commands = ShippedPlugins.commands(in: registry)
        let server = CommandServer(commands: CommandServer.Commands(specs: commands.specs, run: commands.run))
        do {
            try server.start()
            commandServer = server
        } catch {
            // The app works without it; only `canvas` can't reach it.
            NSLog("The command line can't reach this app: %@", "\(error)")
        }
        let app = NSApplication.shared
        app.delegate = delegate
        BoardMenus.install(appName: "Infinite Canvas", helpItems: [
            NSMenuItem(title: "Welcome Board", action: #selector(AppDelegate.showWelcomeBoard(_:)), keyEquivalent: ""),
        ])
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let hasShownWelcomeBoard = "hasShownWelcomeBoard"
    /// The Settings window, its panes the shipped plugins': set once the registry is made.
    var settings: SettingsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Launched with nothing to open: the welcome board the first time, an empty board after that.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        let defaults = UserDefaults.standard
        let firstTime = !defaults.bool(forKey: Self.hasShownWelcomeBoard)
        defaults.set(true, forKey: Self.hasShownWelcomeBoard)
        return openNewBoard(with: firstTime ? WelcomeBoard.document() : CanvasDocument())
    }

    func applicationWillTerminate(_ notification: Notification) {
        for case let board as BoardDocument in NSDocumentController.shared.documents { board.rememberView() }
        InfiniteCanvasApp.commandServer?.stop()
    }

    /// Infinite Canvas › Settings… (⌘,; `BoardMenus.showSettings`): the one Settings window, its
    /// content made afresh each time it opens.
    @objc func showSettings(_ sender: Any?) {
        settings?.show()
    }

    /// Help › Welcome Board: a new board with the welcome notes on it.
    @objc func showWelcomeBoard(_ sender: Any?) {
        openNewBoard(with: WelcomeBoard.document())
    }

    @discardableResult
    private func openNewBoard(with shapes: CanvasDocument) -> Bool {
        let controller = NSDocumentController.shared
        do {
            guard let board = try controller.makeUntitledDocument(ofType: BoardConfiguration.typeIdentifier) as? BoardDocument else { return false }
            board.start(with: shapes)
            board.openWindow()
            return true
        } catch {
            NSApp.presentError(error)
            return false
        }
    }
}

/// A board window's content: the canvas (with the minimap in its corner), the tools in the toolbar,
/// and around it what the plugins gave the host's slots, placed by CanvasUI's `BoardChrome`: inside
/// a subboard the path over its top middle, a palette, and the details in an inspector.
struct ContentView: View {
    let editor: CanvasEditor
    let focus: CanvasFocus
    @Bindable var view: BoardViewState

    init(board: BoardWindowContent) {
        editor = board.editor
        focus = board.focus
        view = board.view
    }

    var body: some View {
        CanvasRepresentable(editor: editor, focus: focus, showsMinimap: view.showsMinimap)
            .frame(minWidth: 480, minHeight: 320)
            .toolbar {
                ToolbarItem(placement: .principal) { ToolPicker(editor: editor) }
            }
            // Last: the path, the palette and the inspector go around the framed, toolbarred canvas.
            .modifier(BoardChrome(editor: editor, showsInspector: $view.showsDetails, onExit: focus.take))
    }
}
