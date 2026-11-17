import OSLog

/// Unified logging. Debug and info messages cost nothing unless a log stream is attached.
nonisolated enum Log {
    static let camera = Logger(subsystem: "io.github.runzeni.spektracam", category: "Camera")
    static let rendering = Logger(subsystem: "io.github.runzeni.spektracam", category: "Rendering")
}
