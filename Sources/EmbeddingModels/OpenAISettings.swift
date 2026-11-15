import AppKit
import Foundation
import LanguageModels
import SwiftUI

extension Notification.Name {
    /// Posted on the main thread when the OpenAI key is saved, replaced or removed in Settings
    /// (`OpenAIKeySettings`). Nothing listens for it: a measure is a one-shot command, so what failed
    /// for want of a key is asked again by the next one, not by itself. `KeyService` requires the name.
    public static let embeddingModelKeyDidChange = Notification.Name("EmbeddingModels.keyDidChange")
}

extension KeyService {
    /// OpenAI's: text-embedding-3-large, the embedding model.
    public static let openAI = KeyService(name: "OpenAI", placeholder: "Not saved", console: URL(string: "https://platform.openai.com/api-keys")!,
                                          keyDidChange: .embeddingModelKeyDidChange)
}

/// The OpenAI key's settings: `KeySettings` made for OpenAI, tested with a one-text call.
public typealias OpenAIKeySettings = KeySettings

extension KeySettings {
    /// The OpenAI key in `keys`, tested with `model` (by default, text-embedding-3-large reading `keys`).
    public convenience init(keys: OpenAIKeyStore, model: (any EmbeddingModel)? = nil) {
        let model = model ?? OpenAIEmbeddingModel(keys: keys)
        self.init(service: .openAI, keys: keys) {
            do throws(EmbeddingModelError) {
                _ = try await model.embed(OpenAISettingsView.testRequest)
                return nil
            } catch {
                return error.message
            }
        }
    }
}

/// The Settings window's OpenAI pane: the API key the embedding model is asked with, in a
/// `KeySettingsView`, laid out as Anthropic's and TypeSafe's and under them. The app hosts it (Infinite
/// Canvas › Settings…, ⌘,), afresh each time the window opens. A text sent for its vector leaves the
/// machine for OpenAI: saving a key is what allows it.
public struct OpenAISettingsView: View {
    /// What the pane is called in the Settings window.
    public static let pane = "OpenAI"

    private let keys: OpenAIKeyStore
    private let model: (any EmbeddingModel)?

    /// The key in `keys`, tested with `model` (by default, OpenAI's reading `keys`).
    public init(keys: OpenAIKeyStore = .standard, model: (any EmbeddingModel)? = nil) {
        self.keys = keys
        self.model = model
    }

    /// The texts Test sends: one, as small as a real call gets.
    public static let testRequest = ["Test"]

    /// Opens Settings, where the key is saved: the same action Anthropic's pane sends up the
    /// responder chain (`AnthropicSettingsView.showSettingsAction`). False if nothing answered it.
    @discardableResult
    public static func showSettings() -> Bool { AnthropicSettingsView.showSettings() }

    public var body: some View {
        KeySettingsView(settings: OpenAIKeySettings(keys: keys, model: model))
    }
}
