import AppKit
import Palette

/// Every number of the reach's look and timing: how a shape's strength
/// falls with its hop and how the reach divides, the rings it is drawn with, the steps the dim's focus
/// is snapped to, and how long the pointer rests, the pulse's steps and the release take.
@MainActor
enum ReachStyle {
    /// What each hop past the first keeps of the one before: strength = `hopKeeps`^(hop − 1) × min(1, share).
    nonisolated static let hopKeeps = 0.6
    /// A ring's strength is drawn in steps of 1 / `ringSteps`, so the rings of one answer are a few groups each.
    nonisolated static let ringSteps = 40
    /// A ring under this strength is left out, and its shape sinks into the dimmed board.
    nonisolated static let faintest = 0.04
    /// A ring's width in view points at strength 1, and at none: 1 + 2.5 × strength.
    nonisolated static let widest: CGFloat = 3.5
    nonisolated static let narrowest: CGFloat = 1
    /// The strengths a shape kept by the dim is drawn at, past hop 1 (which is always 1): the nearest of
    /// these. People tell three or four ordered steps apart, and each step the core draws is a layer.
    nonisolated static let fadeSteps: [CGFloat] = [0.65, 0.35, 0.12]
    /// The most an arrow between two shapes of the reach that the reach didn't travel (a cycle's, two at
    /// one hop) is kept at, however near its ends: it isn't the reach's path, so it stays in view without
    /// competing with the arrows that are (on a dense board, full-strength ones read as patches of noise).
    nonisolated static let sparedMost: CGFloat = 0.35
    /// How long the pointer rests on a shape before the board dims and the rest of its reach shows.
    nonisolated static let rest: Duration = .milliseconds(150)
    /// How long nothing is hovered before the dim and the lights go.
    nonisolated static let release: Duration = .milliseconds(150)
    /// Whether the rest of the reach comes in a hop at a time (the pulse) rather than all at once.
    nonisolated static let pulses = true
    /// The pulse: each hop past the first arrives this long after the one before, those from
    /// `pulseTiers` on together; settled a step after the last arrives.
    nonisolated static let pulseStep: Duration = .milliseconds(80)
    /// The tiers the pulse brings in: hops 1, 2, 3, and 4 and beyond.
    nonisolated static let pulseTiers = 4
    /// How long commits must have stopped before the reach is asked again (as the panel's lists wait).
    nonisolated static let settle: Duration = .milliseconds(100)

    /// A shape's strength from its hop (1 and on) and its share of the reach.
    nonisolated static func strength(hop: Int, share: Double) -> Double {
        guard hop > 1 else { return 1 }
        return pow(hopKeeps, Double(hop - 1)) * min(1, max(0, share))
    }

    /// The ring step a strength is drawn at, 1 to `ringSteps`; nil for one under `faintest`.
    nonisolated static func ringStep(_ strength: Double) -> Int? {
        guard strength >= faintest else { return nil }
        return min(ringSteps, max(1, Int((strength * Double(ringSteps)).rounded())))
    }

    /// A ring step's strength.
    nonisolated static func strength(ofStep step: Int) -> CGFloat { CGFloat(step) / CGFloat(ringSteps) }

    /// A ring's width at a strength, in view points.
    nonisolated static func width(_ strength: CGFloat) -> CGFloat { narrowest + (widest - narrowest) * strength }

    /// The strength the dim keeps a shape at: 1 for hop 1, else the nearest of `fadeSteps`.
    nonisolated static func fade(hop: Int, strength: Double) -> CGFloat {
        guard hop > 1, strength < 1 else { return 1 }
        let s = CGFloat(strength)
        return fadeSteps.min { abs($0 - s) < abs($1 - s) } ?? 1
    }

    /// A light's color at a ring step: mixed toward the canvas by its strength, opaque, so an arrow's
    /// own line doesn't show through its cover, in either appearance.
    nonisolated static func color(_ color: NSColor, step: Int) -> NSColor {
        guard step < ringSteps else { return color }
        let strength = Double(strength(ofStep: step))
        return NSColor(name: nil) { appearance in
            let resolved = NSColor.resolved(in: appearance) { color }
            var rgb: RGB?
            appearance.performAsCurrentDrawingAppearance { rgb = RGB(resolved.cgColor) }
            guard let rgb else { return resolved }
            return NSColor(rgb.over(Swatch.canvas[dark: appearance.isDark], alpha: strength))
        }
    }
}
