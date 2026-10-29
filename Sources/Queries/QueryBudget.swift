import CanvasRPC

/// What a query may take, and how often it looks: constants the evaluation reads off the main actor
/// too, so they live on a type that isn't the main actor's.
public enum QueryBudget {
    /// A main slice's thread CPU: a slice stops once this has gone, at least one record done, so it
    /// lasts this plus at most the one record that crosses it.
    public static let slice: Duration = .milliseconds(2)
    /// Past this in a slice, its clock is read after every record.
    public static let everyRecordAfter: Duration = .microseconds(1_500)
    /// How many records a slice asks between reads of its clock while it's early and they're cheap
    /// (a read costs some 0.1 µs; a record that costs more than the time left narrows it).
    public static let clockStride = 16
    /// How long a query asked on the command line's behalf may take in all, from when it's run: `canvas`
    /// waits `RPC.defaultWait` (10 s) for an answer, and a query is refused `too_slow`, with its hint,
    /// two seconds before that runs out rather than left to be given up on (`QueryRequest.deadline`).
    public static let commandDeadline: Duration = .seconds(RPC.defaultWait) - .seconds(2)
    /// How long a query over a small file may go from when it's run (a wait for answers to settle counts),
    /// or from when the main actor last answered a slice it asked for, without finishing: past it, its
    /// evaluation is cancelled and it's refused `too_slow`. So a query is not refused for being starved
    /// by the main actor, as a long one is between the frames of a drag (it can have one slice a frame,
    /// and `:invalid` over a board of 100,000 shapes asks for some 4,000), while it gets answers; one that
    /// runs on without them, off the main actor, or is never answered, is. The command line's.
    public static let deadline: Duration = commandDeadline
    /// A file with more shapes than this gives its queries longer (`deadline(forShapes:)`).
    public static let deadlineFrom = 10_000
    /// What each shape past `deadlineFrom` adds to the deadline: a walk of every shape off the main
    /// actor, which can be all of the time before the first slice or between two, costs some 3 µs a
    /// shape, and a machine that is busy with other things several times that.
    public static let deadlinePerShape: Duration = .microseconds(50)

    /// How long a query may go over a file of `count` shapes, in all its boards: `deadline`, and
    /// `deadlinePerShape` for each shape past `deadlineFrom`. A query asked for the command line is
    /// held to `commandDeadline` in all too (`QueryRequest.deadline`).
    public static func deadline(forShapes count: Int) -> Duration {
        deadline + deadlinePerShape * max(count - deadlineFrom, 0)
    }

    /// How long a query that reads edges waits, at most, for answers still arriving (stand-ins
    /// asked and not answered) before it takes up the file, and goes on with a `pending` warning
    /// past it (`QueryRequest.settle`): what `canvas query` asks for. It is time the query has spent:
    /// the evaluation gets what's left of `deadline`.
    public static let settleWait: Duration = .seconds(2)
    /// How often the evaluation looks whether it's been cancelled: every so many shapes (and before
    /// every slice).
    public static let cancellationStride = 256
    /// A compound with a one-step edge word whose anchors are fewer than this starts from their
    /// edges' far ends, never a walk of every shape.
    public static let seedFromAnchors = 1_024
    /// Text in a listed attribute is cut past this many characters, unless the request names it.
    public static let cut = 500
    /// Rows listed when the request doesn't say. No request is held to a most: a board of any size
    /// has every row a query matches for whoever asks for them (`QueryRequest.every`).
    public static let rows = 100
}
