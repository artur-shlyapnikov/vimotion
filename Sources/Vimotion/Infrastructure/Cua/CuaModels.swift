// CuaModels.swift — Frozen driver DTOs and typed error categories.
// Verbatim from local://vimotion-contract.md ("Frozen types") and plan §3.6.

import Foundation

struct CuaRect: Sendable, Equatable, Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct CuaHealth: Sendable, Equatable {
    var schemaVersion: String?
    var binaryVersion: String?
    var platformSupported: Bool?
    var sessionActive: Bool?
    var bundleIdentity: String?
    var tccAccessibility: Bool?
    var axCapability: Bool?
}

struct CuaWindow: Sendable, Equatable {
    var windowID: UInt32
    var pid: pid_t
    var appName: String?
    var title: String?
    var bounds: CuaRect
    var zIndex: Int?
    var isOnScreen: Bool
    var onCurrentSpace: Bool
}

struct CuaElement: Sendable, Equatable {
    var index: Int
    var token: String
    var role: String
    var label: String?
    var value: String?
    var frame: CuaRect
    var parentIndex: Int?
    var depth: Int
}

struct CuaWindowSnapshot: Sendable, Equatable {
    var pid: pid_t
    var windowID: UInt32
    var snapshotID: String?
    var windowBounds: CuaRect
    var elements: [CuaElement]
    var elementCount: Int
    var degradedReason: String?
    var offSpace: Bool
}

enum CuaError: Error, Sendable, Equatable {
    case driverNotInstalled
    case transportDisconnected
    case incompatibleDriver(missingTools: [String])
    case accessibilityDenied
    case windowNotFound
    case windowOwnerMismatch(actualPID: pid_t)
    case axWindowUnresolved
    case staleElementToken
    case timeout
    case malformedResponse(String)
    case toolRejected(code: String, message: String)
}
