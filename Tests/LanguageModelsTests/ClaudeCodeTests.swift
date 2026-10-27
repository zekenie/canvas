import Foundation
import LanguageModels
import TestKit

/// Claude Code's model and the account, over a script that stands in for `claude` (`FakeClaude`),
/// and what Claude Code really printed (`ClaudeCodeRecordings`): nothing here reaches the network
/// or the person's own Claude Code.
@MainActor let claudeCodeModelTests = Suite("Claude Code's model", [
    test("runs claude -p with the request's model, system prompt and effort, no tools, MCP servers, skills or session, the message on its standard input") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.print, stdout: claudeResult("Yes"))
            let model = ClaudeCodeModel(claudeCode: claude.claudeCode)
            let request = ModelRequest(system: "Answer in one word.", messages: [.user("Is the sky blue?")], maxTokens: 300,
                                       model: "claude-haiku-5-5", effort: "medium")
            expectEqual(try outcome(of: model, request).map(\.text), .success("Yes"))
            expectEqual(claude.arguments(.print), ["-p", "--output-format", "json", "--model", "claude-haiku-5-5", "--tools", "",
                                                   "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                                                   "--system-prompt", "Answer in one word.", "--effort", "medium"])
            expectEqual(claude.input(.print), "Is the sky blue?")
            expectEqual(claude.environment(.print)["CLAUDE_CODE_MAX_OUTPUT_TOKENS"], "300")
            expectEqual(claude.environment(.print)["CLAUDE_CODE_EFFORT_LEVEL"], "medium", "the effort a run applies: the flag isn't")
        }
    },
    test("a request that names no model is asked of Haiku 4.5; one with no system prompt or effort says neither") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.print, stdout: claudeResult("OK"))
            _ = try outcome(of: ClaudeCodeModel(claudeCode: claude.claudeCode))
            let arguments = try require(claude.arguments(.print))
            expectEqual(arguments[arguments.firstIndex(of: "--model")! + 1], "claude-haiku-4-5")
            expect(!arguments.contains("--system-prompt") && !arguments.contains("--effort"), "\(arguments)")
            expectEqual(claude.environment(.print)["CLAUDE_CODE_EFFORT_LEVEL"], nil)
        }
    },
    test("turns before the last go above it, each tagged with who said it") {
        let prompt = ClaudeCodeModel.prompt(for: [.user("Which notes?"), .assistant("note:titled(\"A\""), .user("<error>unclosed</error>")])
        expectEqual(prompt, """
        <earlier_turns>
        <user>
        Which notes?
        </user>
        <assistant>
        note:titled("A"
        </assistant>
        </earlier_turns>

        <error>unclosed</error>
        """)
        expectEqual(ClaudeCodeModel.prompt(for: [.user("Hi")]), "Hi")
    },
    test("its answer, as Claude Code printed one: the result's text, its stop reason, the tokens written to and read from its cache counted in") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.print, stdout: ClaudeCodeRecordings.answer)
            let response = try outcome(of: ClaudeCodeModel(claudeCode: claude.claudeCode)).get()
            expectEqual(response, ModelResponse(text: "OK", stopReason: .endTurn, inputTokens: 632, outputTokens: 4))
        }
    },
    test("an answer past its limit, which Claude Code fails after three more tries, is an answer cut off") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.print, stdout: ClaudeCodeRecordings.cutOff, status: 1)
            let response = try outcome(of: ClaudeCodeModel(claudeCode: claude.claudeCode)).get()
            expectEqual(response, ModelResponse(text: "", stopReason: .maxTokens, inputTokens: 2928, outputTokens: 160))
        }
    },
    test("its failures, as Claude Code printed them: signed out, and a model there isn't, by the status it gives") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.print, stdout: ClaudeCodeRecordings.unknownModel, stderr: "[claude-code:unrecognized_model] {}\n", status: 1)
            let failure = try outcome(of: ClaudeCodeModel(claudeCode: claude.claudeCode))
            guard case let .failure(error) = failure, case let .server(status, _) = error else { return expect(false, "\(failure)") }
            expectEqual(status, 404)
            expectEqual(error.message, "There's an issue with the selected model (claude-nonexistent-9)")
            try claude.answer(.print, stdout: ClaudeCodeRecordings.notLoggedIn, status: 1)
            expectEqual(try outcome(of: ClaudeCodeModel(claudeCode: claude.claudeCode)), .failure(.notSignedIn))
        }
    },
    test("claude gets only who and where the person is and a PATH with its own directory first, then the app's folder and updates off, whatever the app's environment says") {
        let claudeCode = ClaudeCode(executable: URL(fileURLWithPath: "/Users/ann/.local/bin/claude"),
                                    configDirectory: URL(fileURLWithPath: "/Users/ann/Library/Application Support/InfiniteCanvas/claude-code"))
        let environment = claudeCode.environment(for: URL(fileURLWithPath: "/Users/ann/.local/bin/claude"), inherited: [
            "HOME": "/Users/ann", "USER": "ann", "LANG": "en_US.UTF-8", "HTTPS_PROXY": "http://proxy:8080",
            "ANTHROPIC_API_KEY": testKey, "ANTHROPIC_BASE_URL": "http://localhost:1", "CLAUDE_CODE_SIMPLE": "1",
            "CLAUDECODE": "1", "PATH": "/somewhere/else", "CLAUDE_CONFIG_DIR": "/Users/ann/.claude-work",
            "DISABLE_AUTOUPDATER": "0",
        ], extra: ["CLAUDE_CODE_MAX_OUTPUT_TOKENS": "5"])
        expectEqual(environment, [
            "HOME": "/Users/ann", "USER": "ann", "LANG": "en_US.UTF-8", "HTTPS_PROXY": "http://proxy:8080",
            "PATH": "/Users/ann/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "CLAUDE_CONFIG_DIR": "/Users/ann/Library/Application Support/InfiniteCanvas/claude-code",
            "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "5", "DISABLE_AUTOUPDATER": "1",
        ], "the person's own configuration never, a key never, updates never")
    },
    test("the fake claude run by the model gets none of the test's own key or session") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.print, stdout: claudeResult("OK"))
            _ = try outcome(of: ClaudeCodeModel(claudeCode: claude.claudeCode))
            let environment = claude.environment(.print)
            expect(environment.keys.allSatisfy { !$0.hasPrefix("ANTHROPIC_") && !$0.hasPrefix("CLAUDECODE") }, "\(environment.keys.sorted())")
            expectEqual(environment["CLAUDE_CODE_SIMPLE"], nil)
        }
    },
    test("each failure it says as its error: signed out, a plan's limit, overloaded, the network, a status, else its own words") {
        let cases: [(Int?, String, LanguageModelError)] = [
            (nil, "Not logged in · Please run /login", .notSignedIn),
            (nil, "Login expired · Please run /login", .notSignedIn),
            (nil, "Failed to authenticate: OAuth session expired and could not be refreshed", .notSignedIn),
            (nil, "OAuth token revoked", .notSignedIn),
            (401, "Invalid bearer token", .notSignedIn),
            (nil, "You've hit your session limit", .rateLimited),
            (nil, "Claude AI usage limit reached|1792771200", .rateLimited),
            (nil, "Server is temporarily limiting requests", .rateLimited),
            (429, "Too many requests", .rateLimited),
            (529, "Overloaded", .overloaded),
            (nil, "API Error: Repeated 529 Overloaded errors. The API is at capacity", .overloaded),
            (500, "Internal server error", .server(status: 500, message: "Internal server error")),
            (400, "prompt is too long", .server(status: 400, message: "prompt is too long")),
            (nil, "Unable to connect to API (ENOTFOUND)", .network("Unable to connect to API (ENOTFOUND)")),
            (nil, "Request timed out", .timedOut),
            (nil, "Your account is on hold and can't use Claude Code. View details or appeal.",
             .claudeCode("Your account is on hold and can't use Claude Code. View details or appeal.")),
        ]
        for (status, words, error) in cases {
            expectEqual(ClaudeCodeModel.error(status: status, message: words), error, words)
        }
        expectEqual(LanguageModelError.claudeCode("Your account is on hold. View details.").message, "Your account is on hold")
        expectEqual(LanguageModelError.claudeCode("").message, "Claude Code failed")
    },
    test("once claude says the app isn't signed in, calls fail at once and run nothing, until a status says it is") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.print, stdout: ClaudeCodeRecordings.notLoggedIn, status: 1)
            let model = ClaudeCodeModel(claudeCode: claude.claudeCode)
            expectEqual(try outcome(of: model), .failure(.notSignedIn))
            expectEqual(try outcome(of: model), .failure(.notSignedIn))
            expectEqual(claude.started(.print), 1, "the second call ran nothing")
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
            _ = try awaitResult { await claude.claudeCode.status() }
            try claude.answer(.print, stdout: claudeResult("OK"))
            expectEqual(try outcome(of: model).map(\.text), .success("OK"))
        }
    },
    test("an answer is read once claude has ended, though something it started holds its output open") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.print, stdout: claudeResult("OK"))
            try claude.holdOutput(.print)
            defer { claude.endAll(.print) }
            let started = Date()
            expectEqual(try outcome(of: ClaudeCodeModel(claudeCode: claude.claudeCode)).map(\.text), .success("OK"))
            expect(Date().timeIntervalSince(started) < 10, "within the grace, not the held output's 30 s")
        }
    },
    test("output that isn't its JSON is the last line it wrote to standard error, else its exit status") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.print, stdout: "", stderr: "[claude-code:unrecognized_model] {}\nerror: unknown option '--frob'\n", status: 1)
            expectEqual(try outcome(of: ClaudeCodeModel(claudeCode: claude.claudeCode)), .failure(.claudeCode("error: unknown option '--frob'")))
            try claude.answer(.print, stdout: "", status: 3)
            expectEqual(try outcome(of: ClaudeCodeModel(claudeCode: claude.claudeCode)), .failure(.claudeCode("Claude Code exited with status 3")))
        }
    },
    test("with no claude to run, it isn't signed in, and nothing runs") {
        try withTemporaryAccount { _, claude in
            let missing = ClaudeCode(executable: URL(fileURLWithPath: "/nonexistent/claude"), configDirectory: claude.configDirectory)
            expectEqual(try outcome(of: ClaudeCodeModel(claudeCode: missing)), .failure(.notSignedIn))
        }
    },
    test("cancelling the task asking stops claude, and throws cancelled") {
        try withTemporaryAccount { _, claude in
            try claude.hang(.print)
            defer { claude.endAll(.print) }
            let model = ClaudeCodeModel(claudeCode: claude.claudeCode)
            var result: Result<ModelResponse, LanguageModelError>?
            let task = Task {
                do throws(LanguageModelError) {
                    result = .success(try await model.respond(to: ModelRequest(messages: [.user("Hi")])))
                } catch {
                    result = .failure(error)
                }
            }
            expect(runsFor({ claude.isRunning(.print) }), "claude started")
            task.cancel()
            expect(runsFor({ result != nil }), "the call ended")
            expectEqual(result, .failure(.cancelled))
            expect(runsFor({ !claude.isRunning(.print) }), "and claude was stopped")
        }
    },
    test("past its time claude is stopped, and the call has timed out") {
        try withTemporaryAccount { _, claude in
            try claude.hang(.print)
            defer { claude.endAll(.print) }
            let model = ClaudeCodeModel(claudeCode: claude.claudeCode, timeout: 0.3)
            expectEqual(model.timeout(for: ModelRequest(messages: [], maxTokens: 1000)), 10.3)
            expectEqual(try outcome(of: model, ModelRequest(messages: [.user("Hi")], maxTokens: 1)), .failure(.timedOut))
            expect(runsFor({ !claude.isRunning(.print) }), "claude was stopped")
        }
    },
])

@MainActor let claudeCodeTests = Suite("Claude Code", [
    test("its status, as Claude Code printed it: signed in as whom, on which plan; signed out; an answer it can't read is signed out") {
        expectEqual(ClaudeCode.status(fromJSON: Data(ClaudeCodeRecordings.signedIn.utf8)),
                    .signedIn(ClaudeCodeAccount(email: "ann@example.com", plan: "Max")))
        expectEqual(ClaudeCode.status(fromJSON: Data(#"{"loggedIn":true}"#.utf8)), .signedIn(ClaudeCodeAccount()))
        expectEqual(ClaudeCode.status(fromJSON: Data(ClaudeCodeRecordings.signedOut.utf8)), .signedOut)
        expectEqual(ClaudeCode.status(fromJSON: Data("Not logged in. Run claude auth login to authenticate.".utf8)), .signedOut)
    },
    test("asks claude auth status for it; with no claude, it isn't installed") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
            let status = try awaitResult { await claude.claudeCode.status() }
            expectEqual(status, .signedIn(ClaudeCodeAccount(email: "ann@example.com", plan: "Max")))
            expectEqual(claude.arguments(.authStatus), ["auth", "status"])
            let missing = ClaudeCode(executable: URL(fileURLWithPath: "/nonexistent/claude"), configDirectory: claude.configDirectory)
            expectEqual(try awaitResult { await missing.status() }, .notInstalled)
        }
    },
    test("signs in with claude auth login --claudeai, and comes to what claude auth status says after") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.authLogin, stdout: "Opening browser to sign in…\nLogin successful.\n")
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
            let status = try awaitResult { await claude.claudeCode.signIn() }
            expectEqual(claude.arguments(.authLogin), ["auth", "login", "--claudeai"])
            expectEqual(status, .signedIn(ClaudeCodeAccount(email: "ann@example.com", plan: "Max")))
        }
    },
    test("a sign-in cancelled is stopped, and comes to signed out without asking") {
        try withTemporaryAccount { _, claude in
            try claude.hang(.authLogin)
            defer { claude.endAll(.authLogin) }
            var answer: ClaudeCodeStatus?
            let task = Task { answer = await claude.claudeCode.signIn() }
            expect(runsFor({ claude.isRunning(.authLogin) }), "claude auth login started")
            task.cancel()
            expect(runsFor({ answer != nil }), "the sign-in ended")
            expectEqual(answer, .signedOut)
            expect(runsFor({ !claude.isRunning(.authLogin) }), "and claude auth login was stopped")
            expect(!claude.ran(.authStatus))
        }
    },
    test("signs out with claude auth logout, and comes to what claude auth status says after") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.authLogout, stdout: "Successfully logged out from your Anthropic account.\n")
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: false))
            let status = try awaitResult { await claude.claudeCode.signOut() }
            expectEqual(claude.arguments(.authLogout), ["auth", "logout"])
            expectEqual(status, .signedOut)
        }
    },
    test("the login shell's answer is the line after the marker, among whatever its start-up files print") {
        try withTemporaryAccount { _, claude in
            let link = claude.directory.appending(path: "shim", directoryHint: .notDirectory)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: claude.executable)
            let said = "Welcome!\nnvm: using node 24\n\(ClaudeCodeLocator.marker)\(link.path)\n"
            expectEqual(ClaudeCodeLocator.path(fromShellOutput: Data(said.utf8))?.path,
                        claude.directory.resolvingSymlinksInPath().appending(path: "shim").path, "its directory's links followed, not its own")
            expectEqual(ClaudeCodeLocator.path(fromShellOutput: Data("\(ClaudeCodeLocator.marker)\n".utf8)), nil, "not found")
            expectEqual(ClaudeCodeLocator.path(fromShellOutput: Data("\(ClaudeCodeLocator.marker)claude\n".utf8)), nil, "an alias, not a path")
            expectEqual(ClaudeCodeLocator.path(fromShellOutput: Data("\(ClaudeCodeLocator.marker)/nonexistent/claude\n".utf8)), nil)
        }
    },
])

@MainActor let signedInModelTests = Suite("The signed-in model", [
    test("with no way chosen and no key, it's Claude Code's: not signed in until the app is") {
        try withTemporaryAccount { account, claude in
            expectEqual(account.method(), .claudeCode)
            try claude.answer(.print, stdout: ClaudeCodeRecordings.notLoggedIn, status: 1)
            expectEqual(try outcome(of: SignedInModel(account: account)), .failure(.notSignedIn))
            expect(claude.ran(.print))
        }
    },
    test("a key saved before there was a choice is the API key's way") {
        try withTemporaryAccount { account, claude in
            try account.keys.write(testKey)
            expectEqual(account.method(), .apiKey)
            let model = SignedInModel(account: account, withKey: AnthropicModel(keys: account.keys, session: StubProtocol.session(answering: .http(status: 200, body: reply("Hello")))),
                                      throughClaudeCode: ClaudeCodeModel(claudeCode: account.claudeCode))
            expectEqual(try outcome(of: model).map(\.text), .success("Hello"))
            expect(!claude.ran(.print))
        }
    },
    test("the way chosen is kept beside the key, read at every call: Claude Code's, then the key's") {
        try withTemporaryAccount { account, claude in
            try account.keys.write(testKey)
            try claude.answer(.print, stdout: claudeResult("From Claude Code"))
            let model = SignedInModel(account: account, withKey: AnthropicModel(keys: account.keys, session: StubProtocol.session(answering: .http(status: 200, body: reply("From the key")))),
                                      throughClaudeCode: ClaudeCodeModel(claudeCode: account.claudeCode))
            try account.setMethod(.claudeCode)
            expectEqual(try String(contentsOf: account.methodURL, encoding: .utf8), "claude-code")
            expectEqual(account.methodURL.deletingLastPathComponent(), account.keys.url.deletingLastPathComponent())
            expectEqual(try outcome(of: model).map(\.text), .success("From Claude Code"))
            try account.setMethod(.apiKey)
            expectEqual(try outcome(of: model).map(\.text), .success("From the key"))
        }
    },
    test("the app's account keeps its way beside the app's key, and Claude Code's configuration in a folder of the app's beside them") {
        let account = AnthropicAccount.standard
        expectEqual(account.keys, .standard)
        expectEqual(account.methodURL.lastPathComponent, "sign-in")
        let support = AnthropicKeyStore.standard.url.deletingLastPathComponent()
        expectEqual(account.methodURL.deletingLastPathComponent(), support)
        expectEqual(account.claudeCode.configDirectory.lastPathComponent, "claude-code")
        expectEqual(account.claudeCode.configDirectory.deletingLastPathComponent().standardizedFileURL, support.standardizedFileURL)
    },
])

/// How many sign-in changes were posted while `body` ran.
@MainActor
private func signInChanges(_ body: () throws -> Void) rethrows -> Int {
    var count = 0
    let observer = NotificationCenter.default.addObserver(forName: .languageModelSignInDidChange, object: nil, queue: nil) { _ in
        MainActor.assumeIsolated { count += 1 }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    try body()
    return count
}

@MainActor let signInSettingsTests = Suite("The sign-in settings", [
    test("Claude Code's account line: whom the app is signed in as and on which plan, not signed in, or not installed") {
        try withTemporaryAccount { account, claude in
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
            let settings = ClaudeCodeSettings(claudeCode: account.claudeCode, model: ScriptedLanguageModel())
            expectEqual(settings.accountText, "Checking…")
            runsFor({ settings.state != .checking })
            expectEqual(settings.accountText, "ann@example.com · Max")
            expect(settings.canTest && settings.canSignOut && !settings.canSignIn)
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: false))
            settings.refresh()
            expectEqual(settings.accountText, "ann@example.com · Max", "what it said stays until the answer comes")
            runsFor({ settings.state == .signedOut })
            expectEqual(settings.accountText, "Not signed in")
            expect(settings.canSignIn && !settings.canTest && !settings.canSignOut)
            let missing = ClaudeCodeSettings(claudeCode: ClaudeCode(executable: URL(fileURLWithPath: "/nonexistent/claude"),
                                                                    configDirectory: claude.configDirectory), model: ScriptedLanguageModel())
            runsFor({ missing.state != .checking })
            expectEqual(missing.accountText, "Not installed")
            expect(!missing.canSignIn && !missing.canTest)
        }
    },
    test("signing in: Signing in… while the browser waits, then whom, said to VoiceOver and to whoever waits for a sign-in") {
        try withTemporaryAccount { account, claude in
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: false))
            let settings = ClaudeCodeSettings(claudeCode: account.claudeCode, model: ScriptedLanguageModel())
            var heard: [String] = []
            settings.announce = { heard.append($0) }
            runsFor({ settings.state == .signedOut })
            try claude.answer(.authLogin, stdout: "Login successful.\n")
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
            let changes = signInChanges {
                settings.signIn()
                expectEqual(settings.accountText, "Signing in…")
                expect(!settings.canSignIn, "once")
                runsFor({ settings.state != .signingIn })
            }
            expectEqual(settings.accountText, "ann@example.com · Max")
            expectEqual(heard, ["ann@example.com · Max"])
            expectEqual(changes, 1)
        }
    },
    test("a sign-in that comes to none says where it is, and nothing is posted") {
        try withTemporaryAccount { account, claude in
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: false))
            try claude.answer(.authLogin, stdout: "", stderr: "Login cancelled", status: 1)
            let settings = ClaudeCodeSettings(claudeCode: account.claudeCode, model: ScriptedLanguageModel())
            var heard: [String] = []
            settings.announce = { heard.append($0) }
            runsFor({ settings.state == .signedOut })
            let changes = signInChanges {
                settings.signIn()
                runsFor({ settings.state != .signingIn })
            }
            expectEqual(settings.state, .signedOut)
            expectEqual(settings.statusText, nil, "the account line says it")
            expectEqual(heard, ["Not signed in"])
            expectEqual(changes, 0)
        }
    },
    test("Cancel stops the sign-in: claude auth login is stopped, the pane is signed out again, and nothing is posted") {
        try withTemporaryAccount { account, claude in
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: false))
            try claude.hang(.authLogin)
            defer { claude.endAll(.authLogin) }
            let settings = ClaudeCodeSettings(claudeCode: account.claudeCode, model: ScriptedLanguageModel())
            runsFor({ settings.state == .signedOut })
            let changes = signInChanges {
                settings.signIn()
                runsFor({ claude.isRunning(.authLogin) })
                settings.cancelSignIn()
                runsFor({ settings.state != .signingIn })
            }
            expectEqual(settings.state, .signedOut)
            expect(runsFor({ !claude.isRunning(.authLogin) }), "claude auth login was stopped")
            expectEqual(changes, 0)
        }
    },
    test("Sign Out signs the app out, says so to VoiceOver, and posts the change") {
        try withTemporaryAccount { account, claude in
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
            try claude.answer(.authLogout, stdout: "Successfully logged out from your Anthropic account.\n")
            let settings = ClaudeCodeSettings(claudeCode: account.claudeCode, model: ScriptedLanguageModel())
            var heard: [String] = []
            settings.announce = { heard.append($0) }
            runsFor({ settings.canSignOut })
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: false))
            let changes = signInChanges {
                settings.signOut()
                expectEqual(settings.accountText, "Checking…")
                runsFor({ settings.state == .signedOut })
            }
            expect(claude.ran(.authLogout))
            expectEqual(heard, ["Not signed in"])
            expectEqual(changes, 1)
        }
    },
    test("Test asks something tiny of the features' model through Claude Code, and says it works or why not") {
        try withTemporaryAccount { account, claude in
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
            let model = ScriptedLanguageModel()
            model.queue(ModelResponse(text: "OK"))
            model.queue(.rateLimited)
            let settings = ClaudeCodeSettings(claudeCode: account.claudeCode, model: model)
            var heard: [String] = []
            settings.announce = { heard.append($0) }
            runsFor({ settings.canTest })
            settings.test()
            runsFor({ settings.status != .testing })
            expectEqual(model.requests, [ClaudeCodeSettings.testRequest])
            expectEqual(ClaudeCodeSettings.testRequest.model, "claude-haiku-5-5")
            expectEqual(settings.statusText, "Works")
            settings.test()
            runsFor({ settings.status != .testing })
            expectEqual(settings.statusText, "Rate limited")
            expectEqual(heard, ["Testing…", "Works", "Testing…", "Rate limited"])
        }
    },
    test("with no way chosen it's Claude Code's; choosing one keeps it and says so to whoever waits for a sign-in") {
        try withTemporaryAccount { account, _ in
            let settings = SignInSettings(model: SignedInModel(account: account), keyModel: ScriptedLanguageModel(),
                                          claudeCodeModel: ScriptedLanguageModel())
            expectEqual(settings.method, .claudeCode)
            expectEqual(signInChanges { settings.choose(.claudeCode) }, 0, "it's the way already")
            expectEqual(signInChanges { settings.choose(.apiKey) }, 1)
            expectEqual(account.method(), .apiKey)
            expectEqual(settings.method, .apiKey)
            expectEqual(signInChanges { settings.choose(.claudeCode) }, 1)
            expectEqual(account.method(), .claudeCode)
            expectEqual(SignInSettings(model: SignedInModel(account: account)).method, .claudeCode, "read again as Settings opens")
        }
    },
    test("a key saved before there was a choice is the API key's way") {
        try withTemporaryAccount { account, _ in
            try account.keys.write(testKey)
            let settings = SignInSettings(model: SignedInModel(account: account), keyModel: ScriptedLanguageModel(),
                                          claudeCodeModel: ScriptedLanguageModel())
            expectEqual(settings.method, .apiKey)
            expect(settings.key.hasKey)
        }
    },
    test("with the API key's way, claude is never run, the app coming forward or not; choosing Claude Code's asks it") {
        try withTemporaryAccount { account, claude in
            try account.setMethod(.apiKey)
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
            let settings = SignInSettings(model: SignedInModel(account: account), keyModel: ScriptedLanguageModel(),
                                          claudeCodeModel: ScriptedLanguageModel())
            settings.refresh()                              // the app comes forward
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            expect(!claude.ran(.authStatus), "a key's way never runs claude")
            expectEqual(settings.claudeCode.state, .checking)
            settings.choose(.claudeCode)
            runsFor({ settings.claudeCode.state != .checking })
            expectEqual(settings.claudeCode.accountText, "ann@example.com · Max")
        }
    },
])

@MainActor let signInLifetimeTests = Suite("A sign-in's lifetime", [
    test("a sign-in found by a later look says so to whoever waits for one; the first answer doesn't") {
        try withTemporaryAccount { account, claude in
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: false))
            var settings: ClaudeCodeSettings?
            let first = signInChanges {
                settings = ClaudeCodeSettings(claudeCode: account.claudeCode, model: ScriptedLanguageModel())
                runsFor({ settings?.state == .signedOut })
            }
            expectEqual(first, 0)
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
            let found = signInChanges {
                settings?.refresh()
                runsFor({ settings?.accountText == "ann@example.com · Max" })
            }
            expectEqual(found, 1, "once, signed out to in")
        }
    },
    test("a sign-in outlives the settings that started it, and settings made meanwhile wait for it") {
        try withTemporaryAccount { account, claude in
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: false))
            try claude.hang(.authLogin)
            defer { claude.endAll(.authLogin) }
            var settings: ClaudeCodeSettings? = ClaudeCodeSettings(claudeCode: account.claudeCode, model: ScriptedLanguageModel())
            runsFor({ settings?.state == .signedOut })
            settings?.signIn()
            runsFor({ claude.pid(.authLogin) != nil })     // waiting in the browser
            settings = nil                                  // Settings closed while the browser waits
            let reopened = ClaudeCodeSettings(claudeCode: account.claudeCode, model: ScriptedLanguageModel())
            expectEqual(reopened.state, .signingIn)
            // The person approves: the login ends, and Claude Code says the app is signed in.
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
            let changes = signInChanges {
                _ = try? FileManager.default.removeItem(at: claude.directory.appending(path: "hang-auth-login", directoryHint: .notDirectory))
                if let pid = claude.pid(.authLogin) { kill(pid, SIGTERM) }
                runsFor({ reopened.state != .signingIn })
            }
            expectEqual(reopened.accountText, "ann@example.com · Max")
            expectEqual(changes, 1)
        }
    },
    test("a sign-in under way in one folder is that folder's: settings over another ask their own") {
        try withTemporaryAccount { first, firstClaude in
            try firstClaude.answer(.authStatus, stdout: claudeStatus(signedIn: false))
            try firstClaude.hang(.authLogin)
            defer { firstClaude.endAll(.authLogin) }
            let signingIn = ClaudeCodeSettings(claudeCode: first.claudeCode, model: ScriptedLanguageModel())
            runsFor({ signingIn.state == .signedOut })
            signingIn.signIn()
            runsFor({ firstClaude.pid(.authLogin) != nil })
            try withTemporaryAccount { second, secondClaude in
                try secondClaude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
                let other = ClaudeCodeSettings(claudeCode: second.claudeCode, model: ScriptedLanguageModel())
                expectEqual(other.state, .checking)
                runsFor({ other.state != .checking })
                expectEqual(other.accountText, "ann@example.com · Max")
                other.cancelSignIn()
                expect(firstClaude.isRunning(.authLogin), "the first folder's sign-in goes on")
            }
            signingIn.cancelSignIn()
            runsFor({ signingIn.state == .signedOut })
        }
    },
])

/// What a call through `model` comes to, run as a task the test can cancel; `result` is set as it ends.
@MainActor private final class Call {
    var result: Result<ModelResponse, LanguageModelError>?
    var task: Task<Void, Never>?

    init(_ model: ClaudeCodeModel) {
        task = Task { [weak self] in
            let outcome: Result<ModelResponse, LanguageModelError>
            do throws(LanguageModelError) {
                outcome = .success(try await model.respond(to: ModelRequest(messages: [.user("Hi")])))
            } catch {
                outcome = .failure(error)
            }
            self?.result = outcome
        }
    }
}

@MainActor let personsClaudeCodeTests = Suite("The person's own Claude Code", [
    test("every run of claude is in the app's folder with updates off: a call, a status check, a sign-in, a sign-out") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.print, stdout: claudeResult("OK"))
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
            try claude.answer(.authLogin, stdout: "Login successful.\n")
            try claude.answer(.authLogout, stdout: "Successfully logged out from your Anthropic account.\n")
            _ = try outcome(of: ClaudeCodeModel(claudeCode: claude.claudeCode))
            _ = try awaitResult { await claude.claudeCode.signIn() }
            _ = try awaitResult { await claude.claudeCode.signOut() }
            for command in [FakeClaude.Command.print, .authStatus, .authLogin, .authLogout] {
                let environment = claude.environment(command)
                expectEqual(environment["DISABLE_AUTOUPDATER"], "1", command.rawValue)
                expectEqual(environment["CLAUDE_CONFIG_DIR"], claude.configDirectory.path, command.rawValue)
            }
        }
    },
    test("the app's folder is made before a run, and only its owner may read it") {
        try withTemporaryAccount { _, claude in
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: false))
            expect(!FileManager.default.fileExists(atPath: claude.configDirectory.path))
            _ = try awaitResult { await claude.claudeCode.status() }
            let attributes = try FileManager.default.attributesOfItem(atPath: claude.configDirectory.path)
            expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    },
    test("a status check given up on is stopped, and comes to signed out") {
        try withTemporaryAccount { _, claude in
            try claude.hang(.authStatus)
            defer { claude.endAll(.authStatus) }
            var answer: ClaudeCodeStatus?
            let task = Task { answer = await claude.claudeCode.status() }
            runsFor({ claude.isRunning(.authStatus) })
            task.cancel()
            runsFor({ answer != nil })
            expectEqual(answer, .signedOut)
            expect(runsFor({ !claude.isRunning(.authStatus) }), "claude auth status was stopped")
        }
    },
    test("at most as many calls run at once as there are turns; the next starts as one ends, and waiting can be cancelled") {
        try withTemporaryAccount { _, claude in
            try claude.hang(.print)
            defer { claude.endAll(.print) }
            let model = ClaudeCodeModel(model: AnthropicModel.haiku, claudeCode: claude.claudeCode, timeout: 60, turns: ClaudeCodeTurns(limit: 2))
            let calls = (0..<4).map { _ in Call(model) }
            runsFor({ claude.started(.print) == 2 })
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))   // time for a third to start, were it let
            expectEqual(claude.started(.print), 2, "two turns, two runs")
            calls[3].task?.cancel()
            runsFor({ calls[3].result != nil })
            expectEqual(calls[3].result, .failure(.cancelled), "cancelled while it waited its turn")
            expectEqual(claude.started(.print), 2, "and never run")
            calls[0].task?.cancel()
            runsFor({ claude.started(.print) == 3 })
            expectEqual(calls[0].result ?? .failure(.cancelled), .failure(.cancelled))
            calls[1].task?.cancel()
            calls[2].task?.cancel()
            runsFor({ calls.allSatisfy { $0.result != nil } })
        }
    },
])
