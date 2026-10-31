import Canvas
import CanvasRPC
import CryptoKit
import Foundation

/// The answers decision models gave, kept by what was asked: the model, by name, and the whole request
/// (its state, preface and questions), by a hash of it. A request asked again, in this file or another,
/// after the app opens again too, is answered from here and asks nothing. In memory, and in a file in
/// Application Support where the app keeps one (`DecisionModelsPlugin()`); a test's is in memory only.
/// An answer is kept the day it was given: a plugin whose answers may change from one day to the next
/// says the day in its state.
@MainActor
public final class DecisionMemory {
    /// What's kept of an answer.
    struct Kept: Codable, Equatable {
        var model: String
        var yes: [String: Double]
        var day: String
    }

    /// Where it's kept between launches; nil for memory only.
    public let url: URL?
    /// Today, as kept answers are dated: the system's, unless a test says.
    let today: @Sendable () -> String
    private var kept: [String: Kept] = [:]
    private var loaded = false
    private var changed = false

    public nonisolated init(url: URL?, today: @escaping @Sendable () -> String = DecisionMemory.systemToday) {
        self.url = url
        self.today = today
    }

    /// The app's: `~/Library/Application Support/InfiniteCanvas/decision-answers.json`.
    public nonisolated static func standard() -> DecisionMemory {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return DecisionMemory(url: support.appending(path: "InfiniteCanvas/decision-answers.json", directoryHint: .notDirectory))
    }

    /// The day as answers are dated: the user's own calendar day, as an ISO date.
    public nonisolated static func systemToday() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// What `model` answered `request` today, if it was asked.
    public func answers(to request: DecisionRequest, from model: any DecisionModel) -> DecisionAnswers? {
        load()
        guard let kept = kept[Self.key(request, model: model.name)], kept.day == today() else { return nil }
        return DecisionAnswers(model: kept.model, yes: kept.yes)
    }

    /// Keeps what `model` answered `request`, and lets go of every answer from another day.
    public func keep(_ answers: DecisionAnswers, to request: DecisionRequest, from model: any DecisionModel) {
        load()
        let day = today()
        if kept.values.contains(where: { $0.day != day }) { kept = kept.filter { $0.value.day == day } }
        kept[Self.key(request, model: model.name)] = Kept(model: answers.model, yes: answers.yes, day: day)
        changed = true
    }

    /// Writes what's kept to its file, if anything changed since it was read or last written: whole,
    /// under another name, then renamed into place. A failure keeps it in memory, to try again.
    public func save() {
        guard changed, let url else { return }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            changed = false
        } catch {}
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url, let data = try? Data(contentsOf: url), let read = try? JSONDecoder().decode([String: Kept].self, from: data) else { return }
        let day = today()
        kept = read.filter { $0.value.day == day }.merging(kept) { _, new in new }
    }

    /// The model's name and a hash of the request as one line of JSON, sorted keys.
    static func key(_ request: DecisionRequest, model: String) -> String {
        let questions: [JSONValue] = request.questions.map {
            ["id": .string($0.id), "asks": .string($0.asks), "yes": .string($0.yes), "no": .string($0.no)]
        }
        let preface: JSONValue = request.preface.map { .string($0) } ?? .null
        let asked: JSONValue = ["state": request.state, "preface": preface, "questions": .array(questions)]
        let digest = SHA256.hash(data: Data(asked.compactText.utf8))
        return model + " " + digest.map { String(format: "%02x", $0) }.joined()
    }
}
