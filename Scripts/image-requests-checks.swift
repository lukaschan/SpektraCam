import Foundation

private actor Work {
    var started = 0, completed = 0, cancelled = 0
    func run() async throws -> Int {
        started += 1
        let value = started
        do { try await Task.sleep(for: .milliseconds(250)) }
        catch { cancelled += 1; throw error }
        completed += 1
        return value
    }
}

@main struct ImageRequestChecks {
    static func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            precondition(ContinuousClock.now < deadline, "Image request state did not advance")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    static func cancelled(_ task: Task<Int, Error>) async {
        do { _ = try await task.value; preconditionFailure("Cancelled consumer received an image") }
        catch is CancellationError {}
        catch { preconditionFailure("Unexpected request failure: \(error)") }
    }
    static func main() async throws {
        let pool = ImageRequestPool<Int>()
        let work = Work()
        let first = Task { try await pool.value(for: "shared") { try await work.run() } }
        try await wait { await pool.snapshot.consumers == 1 }
        let second = Task { try await pool.value(for: "shared") { try await work.run() } }
        try await wait { await pool.snapshot.consumers == 2 }
        first.cancel()
        try await wait { await pool.snapshot.consumers == 1 }
        let result = try await second.value
        await cancelled(first)
        precondition(result == 1)
        let starts = await work.started, finishes = await work.completed, cancellations = await work.cancelled
        precondition(starts == 1 && finishes == 1 && cancellations == 0,
            "A departing consumer cancelled shared visible work")
        print("PASS: simultaneous consumers share one load; one cancelled consumer preserves the other")

        let abandoned = Work()
        let last = Task { try await pool.value(for: "abandoned") { try await abandoned.run() } }
        try await wait { await abandoned.started == 1 }
        last.cancel()
        await cancelled(last)
        let stopped = await abandoned.cancelled, abandonedCompleted = await abandoned.completed
        precondition(stopped == 1 && abandonedCompleted == 0)
        print("PASS: the last departing consumer cancels the actual work")

        let background = Work()
        let visible = Task { try await pool.value(for: "background") { try await background.run() } }
        try await wait { await background.started == 1 }
        let editor = UUID(), export = UUID()
        await pool.pause(owner: editor)
        await pool.pause(owner: export)
        try await wait { await pool.snapshot.waiting == 1 }
        await pool.resume(owner: editor)
        let stillPaused = await pool.snapshot
        precondition(stillPaused.owners == 1 && stillPaused.active == 0)
        let parked = Task { try await pool.value(for: "parked") { 99 } }
        try await wait { await pool.snapshot.waiting == 2 }
        parked.cancel()
        await cancelled(parked)
        try await wait { await pool.snapshot.waiting == 1 }
        await pool.resume(owner: export)
        let resumed = try await visible.value
        let interrupted = await background.cancelled, restarted = await background.started
        precondition(resumed == 2 && interrupted == 1 && restarted == 2)
        print("PASS: editor/export ownership interrupts background work, parks without polling and resumes visible consumers after the final owner leaves")

        let spontaneous = Task<Int, Error> {
            try await pool.value(for: "cancelled-operation") { throw CancellationError() }
        }
        await cancelled(spontaneous)
        let final = await pool.snapshot
        precondition(final.active == 0 && final.consumers == 0 && final.waiting == 0 && final.owners == 0)
        print("PASS: operation cancellation propagates and every request/owner is released")
    }
}
