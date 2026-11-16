import Canvas

/// Which way a hover lights, one per editor: one hop (`NeighborState`, as it always has) or, while View
/// › Show Whole Reach is on, the whole reach (`ReachState`). Only the one the setting chooses exists, so
/// the other asks nothing and hands the core nothing; a change of the setting, from any window, makes
/// the other in its place at once.
@MainActor
public final class HoverLights {
    private unowned let editor: CanvasEditor
    private let lights: [NeighborLight]
    private let settings: ReachSettings
    /// One hop, while the whole reach is off.
    public private(set) var oneHop: NeighborState?
    /// The whole reach, while it's on.
    public private(set) var reach: ReachState?

    init(editor: CanvasEditor, lights: [NeighborLight], settings: ReachSettings) {
        self.editor = editor
        self.lights = lights
        self.settings = settings
        make()
        settings.follow(self) { [weak self] in self?.switched() }
    }

    private func make() {
        if settings.showsWholeReach {
            oneHop = nil
            reach = ReachState(editor: editor, lights: lights, settings: settings)
        } else {
            reach?.stop()
            reach = nil
            let made = NeighborState(editor: editor, lights: lights)
            oneHop = made
            // A shape hovered as the way changes is lit at once, as the whole reach's is when it comes on.
            made.askAboutSubject()
        }
    }

    private func switched() {
        guard settings.showsWholeReach != (reach != nil) else { return }
        make()
        editor.setNeedsDisplay()
    }

    /// What the core outlines for the hover, whichever way it lights.
    var outlines: Outlines { reach?.outlines ?? oneHop?.outlines ?? Outlines() }
}

extension HoverLights: EditorService {
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        oneHop?.documentDidChange(changes, in: editor)
        reach?.documentDidChange(changes)
    }

    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        oneHop?.boardDidChange(change, in: editor)
        reach?.boardDidChange()
    }
}
