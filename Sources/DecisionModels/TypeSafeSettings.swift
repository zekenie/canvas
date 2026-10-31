import AppKit
import CanvasRPC
import Foundation
import LanguageModels
import SwiftUI

extension Notification.Name {
    /// Posted on the main thread when the TypeSafe key is saved, replaced or removed in Settings
    /// (`TypeSafeKeySettings`): what failed for want of a key may go now, so a plugin that said so can
    /// ask again by itself.
    public static let decisionModelKeyDidChange = Notification.Name("DecisionModels.keyDidChange")
}

extension KeyService {
    /// TypeSafe's: Jev, the decision model.
    public static let typeSafe = KeyService(name: "TypeSafe", placeholder: "Not saved", console: URL(string: "https://typesafe.ai")!,
                                            keyDidChange: .decisionModelKeyDidChange)
}

/// The TypeSafe key's settings: `KeySettings` made for TypeSafe, tested with a one-question call.
public typealias TypeSafeKeySettings = KeySettings

extension KeySettings {
    /// The TypeSafe key in `keys`, tested with `model` (by default, Jev reading `keys`).
    public convenience init(keys: TypeSafeKeyStore, model: (any DecisionModel)? = nil) {
        let model = model ?? JevModel(keys: keys)
        self.init(service: .typeSafe, keys: keys) {
            do throws(DecisionModelError) {
                _ = try await model.decide(TypeSafeSettingsView.testRequest)
                return nil
            } catch {
                return error.message
            }
        }
    }
}

/// The Settings window's TypeSafe pane: the API key Jev is asked with, in a `KeySettingsView`, laid
/// out as Anthropic's and under it. The app hosts it (Infinite Canvas › Settings…, ⌘,), afresh each
/// time the window opens.
public struct TypeSafeSettingsView: View {
    /// What the pane is called in the Settings window.
    public static let pane = "TypeSafe"

    private let keys: TypeSafeKeyStore
    private let model: (any DecisionModel)?

    /// The key in `keys`, tested with `model` (by default, Jev reading `keys`).
    public init(keys: TypeSafeKeyStore = .standard, model: (any DecisionModel)? = nil) {
        self.keys = keys
        self.model = model
    }

    /// The request Test sends: one question, as small as a real call gets.
    public static let testRequest = DecisionRequest(state: ["test": true],
                                                    questions: [DecisionQuestion(id: "test", asks: "Is this a test?")])

    /// Opens Settings, where the key is saved: the same action Anthropic's pane sends up the
    /// responder chain (`AnthropicSettingsView.showSettingsAction`). False if nothing answered it.
    @discardableResult
    public static func showSettings() -> Bool { AnthropicSettingsView.showSettings() }

    public var body: some View {
        KeySettingsView(settings: TypeSafeKeySettings(keys: keys, model: model))
    }
}
