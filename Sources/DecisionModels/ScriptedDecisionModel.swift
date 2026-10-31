/// A decision model for tests: it keeps every request it's asked, answers each from a queue of
/// answers (answers or an error) in the order they were queued, and, while `holdsAnswers`, keeps
/// every call waiting until the test calls `release()` (to see what's shown while a call is out).
/// With nothing queued, a call answers `fallback`'s answer, else fails with `.server(status: 0, …)`.
/// Never reaches the network.
///
/// Calls land on the main actor: a test that makes one runs the main run loop until it's done
/// (TestKit's `spinRunLoop(until:)`).
@MainActor
public final class ScriptedDecisionModel: DecisionModel {
    /// What the model's answers say it is.
    public nonisolated static let name = "scripted"
    /// What its errors call it.
    public static let provider = "Scripted"

    /// Every request asked, in order, answered or not.
    public private(set) var requests: [DecisionRequest] = []
    /// The answers not yet given.
    public private(set) var queued: [Result<DecisionAnswers, DecisionModelError>] = []
    /// How many calls have been answered (with answers or an error, cancelled ones included).
    public private(set) var answered = 0
    /// While true, each call waits, once its request is kept, until `release()`.
    public var holdsAnswers = false
    /// Answers a call when nothing is queued.
    public var fallback: (@MainActor (DecisionRequest) -> Result<DecisionAnswers, DecisionModelError>)?
    /// Read from any thread, as every model's are.
    public nonisolated let cutoffs: DecisionCutoffs
    public nonisolated var name: String { Self.name }

    private var held: [(id: Int, resume: CheckedContinuation<Void, Never>)] = []
    private var nextID = 0

    public init(cutoffs: DecisionCutoffs = .standard) {
        self.cutoffs = cutoffs
    }

    /// The last request asked.
    public var lastRequest: DecisionRequest? { requests.last }
    /// How many calls are waiting for `release()`.
    public var waiting: Int { held.count }

    /// Queues answers: each question's probability of yes, by its id.
    public func queue(yes: [String: Double]) { queue(DecisionAnswers(model: Self.name, yes: yes)) }

    public func queue(_ answers: DecisionAnswers) { queued.append(.success(answers)) }

    /// Queues a failure: the call it answers throws `error`.
    public func queue(_ error: DecisionModelError) { queued.append(.failure(error)) }

    /// Queues a failure of the scripted provider's.
    public func queue(_ failure: DecisionModelError.Failure) { queue(DecisionModelError(failure, provider: Self.provider)) }

    /// Answers every question of every request not queued for with `probability`.
    public func answerAll(_ probability: Double) {
        fallback = { request in .success(DecisionAnswers(model: Self.name, yes: Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, probability) }))) }
    }

    /// Lets every waiting call go on, in the order they came, each taking the next queued answer as
    /// it does (after this returns, once the main run loop turns). Calls made later still wait while
    /// `holdsAnswers`.
    public func release() {
        let waiting = held
        held.removeAll()
        for call in waiting { call.resume.resume() }
    }

    public func decide(_ request: DecisionRequest) async throws(DecisionModelError) -> DecisionAnswers {
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
        if Task.isCancelled { throw DecisionModelError(.cancelled, provider: Self.provider) }
        if !queued.isEmpty { return try queued.removeFirst().get() }
        if let fallback { return try fallback(request).get() }
        throw DecisionModelError(.server(status: 0, message: "ScriptedDecisionModel has no answer queued"), provider: Self.provider)
    }

    private func releaseCancelled(_ id: Int) {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return }
        held.remove(at: index).resume.resume()
    }
}
