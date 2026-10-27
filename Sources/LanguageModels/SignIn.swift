import Foundation

/// How the app signs in to Claude: through the person's Claude Code, on their Claude plan, or with
/// an Anthropic API key they saved.
public enum SignInMethod: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case apiKey = "api-key"
}

/// Everything the app signs in to Claude with: the way chosen (a file beside the key, holding
/// `SignInMethod`'s raw value, so worktree builds and the evaluation scripts read one), the key, and
/// Claude Code. With no way chosen, a key saved is the API key's way, and Claude Code's is the rest.
public struct AnthropicAccount: Sendable {
    /// The file the way chosen is kept in.
    public let methodURL: URL
    public let keys: AnthropicKeyStore
    public let claudeCode: ClaudeCode

    public init(methodURL: URL, keys: AnthropicKeyStore, claudeCode: ClaudeCode) {
        self.methodURL = methodURL
        self.keys = keys
        self.claudeCode = claudeCode
    }

    /// The app's: `~/Library/Application Support/InfiniteCanvas/sign-in`, beside the key, and the
    /// person's Claude Code in the app's folder.
    public static var standard: AnthropicAccount {
        let keys = AnthropicKeyStore.standard
        return AnthropicAccount(methodURL: keys.url.deletingLastPathComponent().appending(path: "sign-in", directoryHint: .notDirectory),
                                keys: keys, claudeCode: .standard)
    }

    /// The way chosen; with none, the API key's if a key is saved, else Claude Code's.
    public func method() -> SignInMethod {
        if let data = FileManager.default.contents(atPath: methodURL.path),
           let method = SignInMethod(rawValue: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
            return method
        }
        return keys.hasKey ? .apiKey : .claudeCode
    }

    /// Keeps `method` as the way chosen, making the directory if need be.
    public func setMethod(_ method: SignInMethod) throws {
        try FileManager.default.createDirectory(at: methodURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(method.rawValue.utf8).write(to: methodURL, options: .atomic)
    }
}

/// The app's model: Claude, asked the way chosen (`AnthropicAccount.method()`, read at every call,
/// so a way chosen in Settings works at once), with a key (`AnthropicModel`) or through Claude Code
/// (`ClaudeCodeModel`).
public struct SignedInModel: LanguageModel {
    public let account: AnthropicAccount
    public let withKey: AnthropicModel
    public let throughClaudeCode: ClaudeCodeModel

    public init(account: AnthropicAccount = .standard) {
        self.init(account: account, withKey: AnthropicModel(keys: account.keys),
                  throughClaudeCode: ClaudeCodeModel(claudeCode: account.claudeCode))
    }

    /// Each way's model given (tests stub the network, and run a script for `claude`).
    public init(account: AnthropicAccount, withKey: AnthropicModel, throughClaudeCode: ClaudeCodeModel) {
        self.account = account
        self.withKey = withKey
        self.throughClaudeCode = throughClaudeCode
    }

    /// The model that answers a request that names none.
    public var model: String { withKey.model }

    public func respond(to request: ModelRequest) async throws(LanguageModelError) -> ModelResponse {
        switch account.method() {
        case .apiKey: try await withKey.respond(to: request)
        case .claudeCode: try await throughClaudeCode.respond(to: request)
        }
    }
}
