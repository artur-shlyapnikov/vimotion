import os

/// Signpost-based hot-path metrics. Interval names are part of the frozen contract.
enum PerformanceMetrics {
    static let signposter = OSSignposter(subsystem: "local.vimotion", category: "hotpath")

    enum Intervals {
        static let activationToWindow = "activation_to_window"
        static let windowToSnapshot = "window_to_snapshot"
        static let snapshotToTargets = "snapshot_to_targets"
        static let targetsToOverlay = "targets_to_overlay"
        static let keyToClick = "key_to_click"
        static let clickToResult = "click_to_result"
    }
}
