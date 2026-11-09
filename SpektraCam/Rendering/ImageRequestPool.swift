import Foundation

/// Coalesce image work, cancel abandoned requests, and park background consumers
/// while an editor or export owns the renderer. One cancelled consumer cannot
/// cancel an image that another visible consumer still needs.
actor ImageRequestPool<Value: Sendable> {
    struct Snapshot: Sendable {
        let active: Int, consumers: Int, waiting: Int, owners: Int
    }
    var snapshot: Snapshot {
        Snapshot(active: requests.count, consumers: requests.values.reduce(0) { $0 + $1.consumers.count },
            waiting: waiting.count, owners: owners.count)
    }
    private struct Request {
        let id: UUID
        let task: Task<Value, Error>
        var consumers: Set<UUID>
    }
    private var requests: [String: Request] = [:]
    private var owners: Set<UUID> = []
    private var generation: UInt64 = 0
    private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var drain: (id: UUID, task: Task<Void, Never>)?

    func value(for key: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        while true {
            try await waitUntilAvailable()
            let admittedGeneration = generation
            do { return try await subscribe(key, operation: operation) }
            catch is CancellationError {
                try Task.checkCancellation()
                // A pause interrupts work, not its still-visible consumers. They
                // retry after the final owner releases the renderer.
                guard generation != admittedGeneration else { throw CancellationError() }
            }
        }
    }

    func pause(owner: UUID) async {
        owners.insert(owner)
        generation &+= 1
        let active = requests.values.map(\.task)
        requests.removeAll()
        for task in active { task.cancel() }
        let previous = drain?.task
        let id = UUID()
        let task = Task {
            if let previous { await previous.value }
            for task in active { _ = await task.result }
        }
        drain = (id, task)
        await task.value
        if drain?.id == id { drain = nil }
    }

    func resume(owner: UUID) {
        owners.remove(owner)
        guard owners.isEmpty else { return }
        let ready = Array(waiting.values)
        waiting.removeAll()
        for continuation in ready { continuation.resume() }
    }

    private func waitUntilAvailable() async throws {
        try Task.checkCancellation()
        while !owners.isEmpty {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiting[id] = continuation }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
            try Task.checkCancellation()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func subscribe(_ key: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let consumer = UUID()
        var request = requests[key] ?? Request(id: UUID(), task: Task { try await operation() }, consumers: [])
        request.consumers.insert(consumer)
        requests[key] = request
        let id = request.id, task = request.task
        defer { release(key, id: id, consumer: consumer) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.release(key, id: id, consumer: consumer) }
        }
    }

    private func release(_ key: String, id: UUID, consumer: UUID) {
        guard var request = requests[key], request.id == id else { return }
        request.consumers.remove(consumer)
        if request.consumers.isEmpty {
            requests[key] = nil
            request.task.cancel()
        } else { requests[key] = request }
    }
}
