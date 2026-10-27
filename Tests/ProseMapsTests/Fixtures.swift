import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import ProseMaps
import TestKit

/// Code, its parts quoted: a target that's a name and a guide, as a tool with no parser of its own
/// writes one.
enum Snippet {}

extension Snippet: ProseTarget {
    static let name = "code"
    static let guide = """
    An address is the shortest stretch of the code, copied exactly, that's written in it only once.

    """
}

/// A recipe's steps, each addressed by its line's number, and a step that's a check (written `3!`) a
/// rule: a target with an address of its own, which finds it itself, and counts how often it does.
enum Steps {}

/// A step's line, and whether the words say it's a check.
struct Step: Hashable, Sendable, LosslessStringConvertible {
    let line: Int
    let isCheck: Bool

    init?(_ text: String) {
        let number = text.hasSuffix("!") ? String(text.dropLast()) : text
        guard let line = Int(number) else { return nil }
        self.line = line
        isCheck = text.hasSuffix("!")
    }

    var description: String { isCheck ? "\(line)!" : "\(line)" }
}

extension Steps: ProseTarget {
    typealias Address = Step
    static let name = "recipe"
    static let guide = "An address is a step's line number, 1 for the first, with ! after it for a step that checks something."
    @MainActor static var located = 0

    static func locate(_ steps: [Step], in recipe: String) -> [Range<String.Index>?] {
        MainActor.assumeIsolated { located += 1 }
        let lines = recipe.split(separator: "\n", omittingEmptySubsequences: false)
        return steps.map { $0.line >= 1 && $0.line <= lines.count ? lines[$0.line - 1].startIndex..<lines[$0.line - 1].endIndex : nil }
    }

    static func role(of step: Step) -> LinkRole { step.isCheck ? .rule : .element }
}

let menuProse = "sum the prices of every item over ten dollars"
let menuCode = """
func total(_ items: [Item]) -> Double {
    items.filter { $0.price > 10 }.reduce(0) { $0 + $1.price }
}
"""
/// What the model links in it: "prices" to a stretch written twice, which leads nowhere.
let menuAnswer = #"[{"text": "sum", "address": "reduce(0) { $0 + $1.price }"}, {"text": "prices", "address": "price"}, "#
    + #"{"text": "every item", "address": "items.filter { $0.price > 10 }"}, {"text": "over ten dollars", "address": "$0.price > 10"}]"#

let pastaProse = "boil the water, add the pasta, and stir if it sticks"
let pastaRecipe = "boil water\nadd pasta\nif it sticks, stir\ndrain"
let pastaAnswer = #"[{"text": "boil", "address": "1"}, {"text": "add the pasta", "address": "2"}, {"text": "stir if it sticks", "address": "3!"}]"#

/// An editor of boxes, pockets and cards whose model answers every request with `answer`, nothing
/// kept from a test before, and frames drawn as the canvas draws them.
@MainActor
final class MapBench {
    let model = ScriptedLanguageModel()
    let h: EditorHarness
    var answer: Result<ModelResponse, LanguageModelError> = .success(ModelResponse(text: menuAnswer))

    init(model installed: Bool = true) throws {
        ProseMapService.forgetEveryAnswer()
        Steps.located = 0
        var plugins: [any CanvasPlugin] = [FixturesPlugin(), PocketsPlugin(), CardsPlugin(), ProseMapsPlugin()]
        if installed { plugins.append(LanguageModelsPlugin(model: model)) }
        h = try EditorHarness(plugins: plugins)
        model.fallback = { [unowned self] _ in self.answer }
    }

    var editor: CanvasEditor { h.editor }
    var maps: ProseMapService { editor.proseMaps! }
    var asked: [ModelRequest] { model.requests }

    /// A box on the board shown.
    func box(at x: CGFloat = 0) -> ShapeID { h.add(Box(CGRect(x: x, y: 0, width: 100, height: 60))) }

    /// What `shape`'s words say of its code, as its reader reads it.
    func read(_ shape: ShapeID, _ prose: String = menuProse, _ code: String = menuCode, ready: Bool = true) -> ProseMap<Snippet>? {
        maps.map(Snippet.self, of: shape, prose: prose, target: code, askingIf: { ready })
    }

    /// The quotes of a map's links, in the prose's order.
    func quotes<T: ProseTarget>(_ map: ProseMap<T>?) -> [String] { map?.links.map(\.quote) ?? [] }

    /// A frame of the canvas: its end hands over what was read.
    func frame() { _ = renderBitmap(editor, size: CGSize(width: 400, height: 300)) }

    /// Waits for every call to land.
    func settle() { spinRunLoop(until: { self.maps.callsOut == 0 && self.maps.callsWaiting == 0 }) }

    /// A sign-in in Settings, as its notification says, heard.
    func keySaved() {
        NotificationCenter.default.post(name: .languageModelSignInDidChange, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}
