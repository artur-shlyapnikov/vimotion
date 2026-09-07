import CoreGraphics
import Foundation

/// Fingerprint used only for stale-token recovery (§3.24). Never persisted.
struct TargetFingerprint: Sendable, Equatable {
    var normalizedRole: String
    var normalizedLabel: String?
    var center: CGPoint      // AppKit screen coords of visibleFrame
    var size: CGSize         // visibleFrame size

    init(normalizedRole: String, normalizedLabel: String?, center: CGPoint, size: CGSize) {
        self.normalizedRole = normalizedRole
        self.normalizedLabel = normalizedLabel
        self.center = center
        self.size = size
    }
}

/// An actionable element prepared for hint rendering and execution.
struct HintTarget: Sendable, Equatable {
    var token: String
    var pid: pid_t
    var windowID: UInt32
    var role: String
    var label: String?
    var sourceFrame: CGRect   // AppKit coords, full element frame (converted)
    var visibleFrame: CGRect  // AppKit coords, element ∩ window bounds (converted)
    var hintCode: HintCode
    var fingerprint: TargetFingerprint

    init(token: String,
         pid: pid_t,
         windowID: UInt32,
         role: String,
         label: String?,
         sourceFrame: CGRect,
         visibleFrame: CGRect,
         hintCode: HintCode,
         fingerprint: TargetFingerprint) {
        self.token = token
        self.pid = pid
        self.windowID = windowID
        self.role = role
        self.label = label
        self.sourceFrame = sourceFrame
        self.visibleFrame = visibleFrame
        self.hintCode = hintCode
        self.fingerprint = fingerprint
    }
}
