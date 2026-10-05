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
    /// How long a query may take from when it's run (a wait for answers to settle counts, and so does
    /// waiting its turn): past it, its evaluation is cancelled and it's refused `too_slow`, before
    /// `canvas`'s 10 s wait runs out.
    public static let deadline: Duration = .seconds(8)
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
    /// Rows listed when the request doesn't say.
    public static let rows = 100
    /// The most rows a request may ask for.
    public static let maxRows = 10_000
}
