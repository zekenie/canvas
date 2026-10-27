import AppKit
import Foundation
import Observation

/// What the Settings window's Claude Code does, apart from its view (so tests drive it headlessly):
/// say whether Claude Code is installed and the app signed in to it, and as whom; sign in (Anthropic's
/// page, in the browser), cancel that, and sign out; and test it with a tiny real call. Coming to
/// signed in posts `languageModelSignInDidChange`, and so does signing out. A sign-in outlives the
/// settings that started it (the person may close Settings while the browser waits): it's the
/// app's one (`ClaudeCodeSignIns`), and settings made meanwhile wait for it. Its status speaks only
/// of a test: the account line says the rest.
@MainActor
@Observable
public final class ClaudeCodeSettings {
    /// What Claude Code is, as far as the pane knows.
    public enum State: Equatable, Sendable {
        /// Asked, not yet answered.
        case checking
        case notInstalled
        case signedOut
        /// Waiting for the person to approve in their browser.
        case signingIn
        case signedIn(ClaudeCodeAccount)
    }

    public enum Status: Equatable, Sendable {
        case idle
        case testing
        /// The test call was answered.
        case works
        /// The test call failed: what went wrong, in a fragment.
        case failed(String)
    }

    public private(set) var state: State = .checking {
        didSet {
            // A sign-in started here is said by `ClaudeCodeSignIns`, and the first answer only says
            // what already was.
            guard case .signedIn = state, state != oldValue, oldValue != .signingIn, hasAnswered else { return }
            NotificationCenter.default.post(name: .languageModelSignInDidChange, object: self)
        }
    }
    public private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue, let text = statusText else { return }
            announce(text)
        }
    }

    /// Says a status to whoever uses VoiceOver, as it changes (`statusText`), and where a sign-in
    /// or a sign-out comes to: by default the app's announcement; a test sets it to hear what was
    /// said.
    @ObservationIgnored public var announce: @MainActor (String) -> Void = AnthropicKeySettings.announceToVoiceOver

    @ObservationIgnored public let claudeCode: ClaudeCode
    @ObservationIgnored private let model: any LanguageModel
    @ObservationIgnored private var checking: Task<Void, Never>?
    @ObservationIgnored private var waitingForSignIn: Task<Void, Never>?
    @ObservationIgnored private var signingOut: Task<Void, Never>?
    @ObservationIgnored private var testing: Task<Void, Never>?
    /// Whether Claude Code has answered since the settings were made.
    @ObservationIgnored private var hasAnswered = false

    /// `model` is what Test asks (by default, Claude through `claudeCode`). Waits for a sign-in under
    /// way; else asks at once whether the app is signed in, when `asksNow` (Claude Code's way is
    /// shown), or stays `checking` until `refresh()`, so a person signed in with a key never has
    /// their `claude` run.
    public init(claudeCode: ClaudeCode, model: (any LanguageModel)? = nil, asksNow: Bool = true) {
        self.claudeCode = claudeCode
        self.model = model ?? ClaudeCodeModel(claudeCode: claudeCode)
        if let underWay = ClaudeCodeSignIns.underWay(for: claudeCode) {
            state = .signingIn
            wait(for: underWay)
        } else if asksNow {
            refresh()
        }
    }

    isolated deinit {
        checking?.cancel()
        waitingForSignIn?.cancel()
        signingOut?.cancel()
        testing?.cancel()
    }

    /// The request Test sends: as small as a real call gets, to the model the features ask, with
    /// room for its thinking.
    public static let testRequest = ModelRequest(system: "Reply with the word OK.", messages: [.user("OK?")], maxTokens: 1024,
                                                 model: "claude-haiku-5-5", effort: "low")

    public var canSignIn: Bool { state == .signedOut }
    public var canTest: Bool {
        guard case .signedIn = state else { return false }
        return status != .testing
    }
    public var canSignOut: Bool {
        guard case .signedIn = state else { return false }
        return status != .testing
    }

    /// Asks Claude Code again whether the app is signed in, unless it's signing in or out. What the
    /// pane said stays until the answer comes, but for the first ask, which says `checking`.
    public func refresh() {
        guard state != .signingIn, signingOut == nil else { return }
        checking?.cancel()
        let claudeCode = claudeCode
        checking = Task {
            let answer = await claudeCode.status()
            guard !Task.isCancelled, state != .signingIn else { return }
            state = State(answer)
            hasAnswered = true
            checking = nil
        }
    }

    /// Signs in through Claude Code: Anthropic's page opens in the browser, and the pane waits for
    /// the person to approve there. Signed in, it says whom (`ClaudeCodeSignIns` posts
    /// `languageModelSignInDidChange`); else it's signed out again.
    public func signIn() {
        guard canSignIn else { return }
        checking?.cancel()
        status = .idle
        state = .signingIn
        wait(for: ClaudeCodeSignIns.start(claudeCode))
    }

    /// Stops the sign-in under way; the pane is signed out again.
    public func cancelSignIn() {
        guard state == .signingIn else { return }
        ClaudeCodeSignIns.cancel(for: claudeCode)
    }

    private func wait(for signIn: Task<ClaudeCodeStatus, Never>) {
        waitingForSignIn = Task {
            let answer = await signIn.value
            guard !Task.isCancelled else { return }
            state = State(answer)
            hasAnswered = true
            waitingForSignIn = nil
            announce(accountText)
        }
    }

    /// Signs the app out of Claude Code (its sign-in revoked), checking meanwhile; what asks then
    /// says Not signed in.
    public func signOut() {
        guard canSignOut else { return }
        checking?.cancel()
        status = .idle
        state = .checking
        let claudeCode = claudeCode
        signingOut = Task {
            let answer = await claudeCode.signOut()
            guard !Task.isCancelled else { return }
            state = State(answer)
            signingOut = nil
            announce(accountText)
            NotificationCenter.default.post(name: .languageModelSignInDidChange, object: self)
        }
    }

    /// Asks Claude something tiny through Claude Code.
    public func test() {
        guard canTest else { return }
        status = .testing
        let model = model
        testing = Task {
            let outcome: Status
            do throws(LanguageModelError) {
                _ = try await model.respond(to: Self.testRequest)
                outcome = .works
            } catch {
                outcome = .failed(error.message)
            }
            guard !Task.isCancelled else { return }
            status = outcome
            testing = nil
        }
    }

    /// The account line: who the app is signed in as ("ann@example.com · Max"), or where it is.
    public var accountText: String {
        switch state {
        case .checking: "Checking…"
        case .notInstalled: "Not installed"
        case .signedOut: "Not signed in"
        case .signingIn: "Signing in…"
        case let .signedIn(account): [account.email, account.plan].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Signed in"
        }
    }

    /// A test's progress or outcome; nil when there's nothing to say.
    public var statusText: String? {
        switch status {
        case .idle: nil
        case .testing: "Testing…"
        case .works: "Works"
        case let .failed(message): message
        }
    }
}

/// The app's sign-in through Claude Code, while one is under way: kept apart from the settings that
/// started it, so closing Settings doesn't stop `claude auth login` while the browser waits. It posts
/// `languageModelSignInDidChange` itself once signed in, whether or not any settings are left to.
@MainActor
enum ClaudeCodeSignIns {
    /// The sign-in under way, and the folder it signs in.
    private static var current: (id: UUID, folder: URL, task: Task<ClaudeCodeStatus, Never>)?

    /// The sign-in under way in `claudeCode`'s folder, if there is one.
    static func underWay(for claudeCode: ClaudeCode) -> Task<ClaudeCodeStatus, Never>? {
        guard let current, current.folder == claudeCode.configDirectory else { return nil }
        return current.task
    }

    /// The sign-in under way in `claudeCode`'s folder, else a new one.
    static func start(_ claudeCode: ClaudeCode) -> Task<ClaudeCodeStatus, Never> {
        if let underWay = underWay(for: claudeCode) { return underWay }
        let id = UUID()
        let signIn = Task {
            let answer = await claudeCode.signIn()
            if current?.id == id { current = nil }
            if case .signedIn = answer { NotificationCenter.default.post(name: .languageModelSignInDidChange, object: nil) }
            return answer
        }
        current = (id, claudeCode.configDirectory, signIn)
        return signIn
    }

    /// Stops the sign-in under way in `claudeCode`'s folder, if there is one: it comes to signed out.
    static func cancel(for claudeCode: ClaudeCode) {
        underWay(for: claudeCode)?.cancel()
    }
}

extension ClaudeCodeSettings.State {
    init(_ status: ClaudeCodeStatus) {
        switch status {
        case .notInstalled: self = .notInstalled
        case .signedOut: self = .signedOut
        case let .signedIn(account): self = .signedIn(account)
        }
    }
}

/// The Settings window's sign-in, apart from its view: the way chosen, and each way's own settings.
/// Choosing a way keeps it (`AnthropicAccount.setMethod`) and posts `languageModelSignInDidChange`;
/// Claude Code is asked whether the app is signed in only while its way is the one chosen.
@MainActor
@Observable
public final class SignInSettings {
    /// The way chosen (with none chosen yet, the one the model asks: `AnthropicAccount.method()`).
    public private(set) var method: SignInMethod
    /// Why the way chosen couldn't be kept, with the system's words; nil when nothing failed.
    public private(set) var failure: String?

    public let account: AnthropicAccount
    public let key: AnthropicKeySettings
    public let claudeCode: ClaudeCodeSettings

    /// Says a failure to keep the way chosen to whoever uses VoiceOver: by default the app's
    /// announcement; a test sets it to hear what was said.
    @ObservationIgnored public var announce: @MainActor (String) -> Void = AnthropicKeySettings.announceToVoiceOver

    /// The ways of `model`'s account; `keyModel` and `claudeCodeModel` are what each way's Test asks
    /// (by default, the model's own for that way).
    public init(model: SignedInModel, keyModel: (any LanguageModel)? = nil, claudeCodeModel: (any LanguageModel)? = nil) {
        let method = model.account.method()
        account = model.account
        self.method = method
        key = AnthropicKeySettings(keys: model.account.keys, model: keyModel ?? model.withKey)
        claudeCode = ClaudeCodeSettings(claudeCode: model.account.claudeCode, model: claudeCodeModel ?? model.throughClaudeCode,
                                        asksNow: method == .claudeCode)
    }

    /// Chooses `method`: kept, and said to whoever waits for a sign-in. Claude Code's way asks
    /// Claude Code where the app stands.
    public func choose(_ method: SignInMethod) {
        guard method != self.method || failure != nil else { return }
        do {
            try account.setMethod(method)
            self.method = method
            failure = nil
            NotificationCenter.default.post(name: .languageModelSignInDidChange, object: self)
        } catch {
            failure = error.localizedDescription
            announce("Couldn’t save")
        }
        if self.method == .claudeCode { claudeCode.refresh() }
    }

    /// Asks Claude Code again where the app stands, if its way is the one chosen (the app has come
    /// forward: Claude Code may have been installed meanwhile).
    public func refresh() {
        if method == .claudeCode { claudeCode.refresh() }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
