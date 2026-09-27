/// A language model for tests: it keeps every request it's asked, answers each from a queue of
/// answers (a response or an error) in the order they were queued, and, while `holdsAnswers`, keeps
/// every call waiting until the test calls `release()` (to see what's shown while a call is out).
/// With nothing queued, a call answers `fallback`'s answer, else fails with
/// `.server(status: 0, …)`. Never reaches the network.
///
/// Calls land on the main actor: a test that makes one runs the main run loop until it's done
/// (TestKit's `spinRunLoop(until:)`).
@MainActor
public final class ScriptedLanguageModel: LanguageModel {
    /// Every request asked, in order, answered or not.
    public private(set) var requests: [ModelRequest] = []
    /// The answers not yet given.
    public private(set) var queued: [Result<ModelResponse, LanguageModelError>] = []
    /// How many calls have been answered (with a response or an error, cancelled ones included).
    public private(set) var answered = 0
    /// While true, each call waits, once its request is kept, until `release()`.
    public var holdsAnswers = false
    /// Answers a call when nothing is queued.
    public var fallback: (@MainActor (ModelRequest) -> Result<ModelResponse, LanguageModelError>)?

    private var held: [(id: Int, resume: CheckedContinuation<Void, Never>)] = []
    private var nextID = 0

    public init(answers: [String] = []) {
        queued = answers.map { .success(ModelResponse(text: $0)) }
    }

    /// The last request asked.
    public var lastRequest: ModelRequest? { requests.last }
    /// How many calls are waiting for `release()`.
    public var waiting: Int { held.count }

    /// Queues an answer that says `text`.
    public func queue(_ text: String, stopReason: StopReason = .endTurn) {
        queue(ModelResponse(text: text, stopReason: stopReason))
    }

    public func queue(_ response: ModelResponse) { queued.append(.success(response)) }

    /// Queues a failure: the call it answers throws `error`.
    public func queue(_ error: LanguageModelError) { queued.append(.failure(error)) }

    /// Lets every waiting call go on, in the order they came, each taking the next queued answer as
    /// it does (after this returns, once the main run loop turns). Calls made later still wait while
    /// `holdsAnswers`.
    public func release() {
        let waiting = held
        held.removeAll()
        for call in waiting { call.resume.resume() }
    }

    public func respond(to request: ModelRequest) async throws(LanguageModelError) -> ModelResponse {
        requests.append(request)
        defer { answered += 1 }
        if holdsAnswers {
            let id = nextID
            nextID += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { held.append((id, $0)) }
            } onCancel: {
                Task { @MainActor in self.releaseCancelled(id) }
            }
        }
        if Task.isCancelled { throw .cancelled }
        if !queued.isEmpty { return try queued.removeFirst().get() }
        if let fallback { return try fallback(request).get() }
        throw .server(status: 0, message: "ScriptedLanguageModel has no answer queued")
    }

    private func releaseCancelled(_ id: Int) {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return }
        held.remove(at: index).resume.resume()
    }
}
