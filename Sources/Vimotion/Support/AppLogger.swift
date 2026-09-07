import os

/// Central logging facade. Privacy rules: never log window titles, AX labels/values,
/// element tokens, or typed key content — only PIDs, window IDs, counts, error
/// categories, timings, and driver versions.
enum AppLogger {
    static let cua = Logger(subsystem: "local.vimotion", category: "cua")
    static let hint = Logger(subsystem: "local.vimotion", category: "hint")
    static let input = Logger(subsystem: "local.vimotion", category: "input")
    static let overlay = Logger(subsystem: "local.vimotion", category: "overlay")
    static let app = Logger(subsystem: "local.vimotion", category: "app")
}
