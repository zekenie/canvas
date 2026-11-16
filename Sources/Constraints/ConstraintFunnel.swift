import Adornments
import AppKit
import Canvas
import DetailPanel
import Selection
import Titles
import Validation

// What a container's constraints look like on the board: a funnel in the row above its top-left corner, after its title's
// pill and the chips of its types. Quiet while every shape inside fits, red with a count when some don't. A click goes to
// the constraints: the container selected (one step back) and its Rules tab chosen.

/// The funnel: a symbol in a disc while everything inside fits, the symbol and how many shapes break a constraint, in red
/// (Validation's error color), when some do. On the kinds that hold constraints, once a constraint applies (its own or
/// what it has from elsewhere); none zoomed out, on a skeleton (no adornment is drawn on one), nor on a type note, which
/// keeps its list in its Rules tab and is no place. A click selects the container and chooses its Rules tab; the tooltip
/// says what it accepts, the words as typed. A part of its shape (⌥Tab, Return), named "Constraints", what it accepts (the
/// first words, "and 2 more") and, when some are broken, how many are not accepted. VoiceOver hears the same of the container itself, after what it is ("accepts only tasks").
public enum ConstraintFunnel {}

extension ConstraintFunnel: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopLeft }
    /// After what a shape is called; a list puts the plugin after the one that gives it what it is, so the chips of its types
    /// come first.
    public static var order: Order<Self> { .after(TitlePill.self) }
}

extension ConstraintFunnel: ClickableAdornment {
    public static var partTitle: String { ConstraintsStyle.chipTitle }

    public static func click(_ click: AdornmentClick, in editor: CanvasEditor) {
        editor.constraintIndex?.showRules(of: click.shape)
    }

    public static func help(for click: AdornmentClick, in editor: CanvasEditor) -> String? {
        editor.constraintIndex?.funnelHelp(of: click.shape)
    }
}

extension ConstraintIndex {
    /// The chip a container shows: nil while no constraint applies. Spoken as the part it is: "Constraints, only tasks", and the
    /// count of shapes that break one, when some do.
    func funnel(of id: ShapeID) -> AdornmentLabel? {
        guard !constraints(of: .shape(id)).isEmpty else { return nil }
        let broken = breakers(of: .shape(id)).count
        let spoken = ConstraintsStyle.chipSpoken(acceptedWords(of: id), notAccepted: broken)
        guard broken > 0 else { return AdornmentLabel(systemImage: ConstraintsStyle.funnelSymbol).spoken(spoken) }
        return AdornmentLabel("\(broken)", systemImage: ConstraintsStyle.funnelSymbol)
            .tinted(AdornmentTint(Severity.error.color, style: .light))
            .spoken(spoken)
    }

    /// The words of each constraint a place has, as typed, each once, in order.
    func acceptedWords(of id: ShapeID) -> [String] { acceptedWords(of: .shape(id)) }

    /// The same, for any place: the root's too.
    func acceptedWords(of place: ConstraintTarget) -> [String] {
        var seen: Set<String> = []
        return constraints(of: place).map(\.constraint.says).filter { seen.insert($0).inserted }
    }

    /// What the chip's tooltip says: the words of each constraint the place has, as typed, each once, and how many shapes break
    /// one.
    func funnelHelp(of id: ShapeID) -> String? { funnelHelp(of: .shape(id)) }

    /// The same, for any place.
    func funnelHelp(of place: ConstraintTarget) -> String? {
        let says = acceptedWords(of: place)
        guard !says.isEmpty else { return nil }
        return ConstraintsStyle.help(says, notAccepted: breakers(of: place).count)
    }

    /// Selects a container and chooses its Rules tab: one step back. What the chip's click and Show Constraints do. The
    /// selection is made on the next turn: a click is still a gesture under way as it's heard, which goes nowhere.
    public func showRules(of holder: ShapeID) {
        guard let editor, let record = editor.shape(inFile: holder) else { return }
        editor.detailPanel?.choose(.of(RulesTab.self), for: record.kind)
        _ = editor.scheduler.schedule(after: .zero) { [weak editor] in editor?.goTo([holder]) }
    }
}

/// The chip, on the kinds that hold constraints, and what VoiceOver says of the container, as Locking says "locked" of a shape.
@MainActor
func registerConstraintFunnel(into registrar: inout PluginRegistrar) {
    registrar.forShapes(holding: ConstraintsProperty.self) { held in
        held.adornment(ConstraintFunnel.self) { shape, context in
            context.service(ConstraintIndex.self)?.funnel(of: shape.id)
        }
        held.accessibility { record, editor in
            guard let says = editor.constraintIndex?.acceptedWords(of: record.id), !says.isEmpty else { return nil }
            return AccessibleTraits(states: [ConstraintsStyle.acceptsSpoken(says)])
        }
    }
}
