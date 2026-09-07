// CuaResponseDecoder.swift — the ONLY production place that inspects the generic
// MCP.Value structure besides argument construction in CuaMCPProcess/CuaDriverClient.
//
// Ground truth verified against the pinned checkout (.build/checkouts/swift-sdk @ 0.12.1):
//   • Sources/MCP/Base/Value.swift:6-14 — `enum Value { case null, bool(Bool), int(Int),
//     double(Double), string(String), data(mimeType:data:), array([Value]), object([String: Value]) }`
//   • Sources/MCP/Server/Tools.swift:405-422 — `CallTool.Result { content: [Tool.Content],
//     structuredContent: Value?, isError: Bool?, _meta: Metadata? }`
//   • Sources/MCP/Server/Tools.swift:117 — `Tool.Content.text(text: String, annotations:, _meta:)`
// Key spellings below follow docs/architecture.md §3.4/§3.6/§3.8 which document the driver's
// snake_case wire format (window_id, element_token, on_screen_only, delivery_mode, …);
// camelCase alternatives are accepted defensively where noted.

import Foundation
import MCP

enum CuaResponseDecoder {
    // MARK: - Public entry points

    /// Decode `health_report` structured output.
    static func health(from result: MCP.CallTool.Result) throws -> CuaHealth {
        let payload = try requiredPayload(of: result, tool: "health_report")
        guard let version = schemaVersion(payload), version == "1" else {
            throw CuaError.malformedResponse(
                "health_report: unsupported schema_version \(describe(payload["schema_version"]))")
        }
        let platformSupported = bool(payload["platform_supported"])
            ?? healthCheckStatus(named: "platform_supported", in: payload)
        let sessionActive = bool(payload["session_active"])
            ?? healthCheckStatus(named: "session_active", in: payload)
        let accessibility = bool(payload["tcc_accessibility"])
            ?? healthCheckStatus(named: "tcc_accessibility", in: payload)
        let axCapability = bool(payload["ax_capability"])
            ?? healthCheckStatus(named: "ax_capability", in: payload)
        let bundleIdentity = string(payload["bundle_identity"])
            ?? healthCheckValue("bundle_identifier", named: "bundle_identity", in: payload)
            ?? healthCheckValue("bundle_identity", named: "bundle_identity", in: payload)
        return CuaHealth(
            schemaVersion: version,
            // CuaDriver 0.21 uses driver_version and a named checks array;
            // older drivers returned the frozen fields at the top level.
            binaryVersion: string(payload["binary_version"]) ?? string(payload["driver_version"]),
            platformSupported: platformSupported,
            sessionActive: sessionActive,
            bundleIdentity: bundleIdentity,
            tccAccessibility: accessibility,
            axCapability: axCapability
        )
    }

    /// Decode `list_windows` output into typed windows.
    ///
    /// Supported key spellings (primary = snake_case per docs/architecture.md §3.6):
    /// window_id | windowId, pid, app_name | appName, title, bounds,
    /// z_index | zIndex, is_on_screen | isOnScreen, on_current_space | onCurrentSpace.
    static func windows(from result: MCP.CallTool.Result) throws -> [CuaWindow] {
        let value = try anyPayload(of: result, tool: "list_windows")
        let items: [MCP.Value]
        switch value {
        case .array(let values):
            items = values
        case .object(let dict):
            // Some drivers wrap the list; accept both spellings of the wrapper key.
            guard let wrapped = array(dict["windows"]) ?? array(dict["results"]) else {
                throw CuaError.malformedResponse("list_windows: expected an array payload")
            }
            items = wrapped
        default:
            throw CuaError.malformedResponse("list_windows: expected an array payload")
        }
        var out: [CuaWindow] = []
        out.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            guard case .object(let dict) = item else {
                throw CuaError.malformedResponse("list_windows: window #\(offset) is not an object")
            }
            guard let windowID = uint32(dict["window_id"] ?? dict["windowId"]) else {
                throw CuaError.malformedResponse("list_windows: window #\(offset) missing window_id")
            }
            guard let pid = int(dict["pid"]).map({ pid_t($0) }) else {
                throw CuaError.malformedResponse("list_windows: window #\(offset) missing pid")
            }
            guard let bounds = rect(dict["bounds"]) else {
                throw CuaError.malformedResponse("list_windows: window #\(offset) missing bounds")
            }
            out.append(
                CuaWindow(
                    windowID: windowID,
                    pid: pid,
                    appName: string(dict["app_name"] ?? dict["appName"]),
                    title: string(dict["title"]),
                    bounds: bounds,
                    zIndex: int(dict["z_index"] ?? dict["zIndex"]),
                    isOnScreen: bool(dict["is_on_screen"] ?? dict["isOnScreen"]) ?? false,
                    onCurrentSpace: bool(dict["on_current_space"] ?? dict["onCurrentSpace"]) ?? false
                ))
        }
        return out
    }

    /// Decode `get_window_state` output into a snapshot.
    ///
    /// Element key spellings (primary = snake_case per docs/architecture.md §3.4):
    /// element_index | index, element_token | token, role, label?, value?,
    /// frame{x,y,width,height}, parent_index?, depth.
    static func snapshot(pid: pid_t, windowID: UInt32, from result: MCP.CallTool.Result) throws
        -> CuaWindowSnapshot
    {
        let payload = try requiredPayload(of: result, tool: "get_window_state")
        guard let bounds = rect(payload["window_bounds"]) else {
            throw CuaError.malformedResponse("get_window_state: missing window_bounds")
        }
        guard let rawElements = array(payload["elements"]) else {
            throw CuaError.malformedResponse("get_window_state: missing elements array")
        }
        var elements: [CuaElement] = []
        elements.reserveCapacity(rawElements.count)
        for (offset, raw) in rawElements.enumerated() {
            guard case .object(let dict) = raw else {
                throw CuaError.malformedResponse("get_window_state: element #\(offset) is not an object")
            }
            guard let index = int(dict["element_index"] ?? dict["index"]) else {
                throw CuaError.malformedResponse("get_window_state: element #\(offset) missing index")
            }
            guard let token = string(dict["element_token"] ?? dict["token"]) else {
                throw CuaError.malformedResponse("get_window_state: element #\(offset) missing token")
            }
            guard let role = string(dict["role"]) else {
                throw CuaError.malformedResponse("get_window_state: element #\(offset) missing role")
            }
            guard let frame = rect(dict["frame"]) else {
                throw CuaError.malformedResponse("get_window_state: element #\(offset) missing frame")
            }
            elements.append(
                CuaElement(
                    index: index,
                    token: token,
                    role: role,
                    label: string(dict["label"]),
                    value: string(dict["value"]),
                    frame: frame,
                    parentIndex: int(dict["parent_index"]),
                    depth: int(dict["depth"]) ?? 0
                ))
        }
        let degraded = string(payload["degraded_reason"])
        // A degraded AX walk reported as ax_window_unresolved stays a typed failure (plan §3.7).
        if degraded == "ax_window_unresolved" {
            throw CuaError.axWindowUnresolved
        }
        return CuaWindowSnapshot(
            pid: pid,
            windowID: windowID,
            snapshotID: string(payload["snapshot_id"]),
            windowBounds: bounds,
            elements: elements,
            elementCount: int(payload["element_count"]) ?? elements.count,
            degradedReason: degraded,
            offSpace: bool(payload["off_space"]) ?? false
        )
    }

    /// Validate a `click` acknowledgement: `{"ok": true}`, an empty object, or an empty
    /// result all mean success; any failure envelope maps exactly like every other tool.
    static func clickAcknowledgement(from result: MCP.CallTool.Result) throws {
        let payload = payloadDict(of: result)
        if result.isError == true || isExplicitError(payload) {
            throw normalizedFailure(of: result, tool: "click")
        }
    }

    // MARK: - Failure normalization

    /// Map a failed tool result to the exact contract errors (plan §3.7).
    static func normalizedFailure(of result: MCP.CallTool.Result, tool: String) -> CuaError {
        guard let payload = payloadDict(of: result) else {
            return .malformedResponse("\(tool): error result without decodable payload")
        }
        return mapFailure(payload)
    }

    private static func mapFailure(_ dict: [String: MCP.Value]) -> CuaError {
        // Drivers may put the code under `code`, use `error` as a code string,
        // or wrap the whole envelope in `error` as a nested object — the nested
        // shape is unpacked and mapped through these same typed rules.
        if case .object(let nested)? = dict["error"] {
            return mapFailure(nested)
        }
        let rawError = dict["error"]
        let code = string(dict["code"]) ?? string(rawError) ?? ""
        let message =
            string(dict["message"])
            ?? (string(rawError) == nil ? describe(rawError) : "")
        switch code {
        case "window_id_not_found":
            return .windowNotFound
        case "window_owner_pid_mismatch":
            // actual_pid is the canonical spelling; actualPID accepted defensively.
            let actual = int(dict["actual_pid"] ?? dict["actualPID"]) ?? -1
            return .windowOwnerMismatch(actualPID: pid_t(actual))
        case "stale_element_token":
            return .staleElementToken
        case "ax_window_unresolved":
            return .axWindowUnresolved
        default:
            if code.contains("accessibility") || code.contains("tcc") {
                return .accessibilityDenied
            }
            return .toolRejected(code: code, message: message)
        }
    }

    // MARK: - Payload extraction

    /// Prefer structuredContent; fall back to the first `.text` content block parsed as JSON object.
    private static func payloadDict(of result: MCP.CallTool.Result) -> [String: MCP.Value]? {
        if case .object(let dict)? = result.structuredContent {
            return dict
        }
        for block in result.content {
            if case .text(let text, _, _) = block, let data = text.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(MCP.Value.self, from: data),
                case .object(let dict) = decoded
            {
                return dict
            }
        }
        return nil
    }

    /// Extract the payload (dict or otherwise) or throw the normalized failure / malformed error.
    private static func anyPayload(of result: MCP.CallTool.Result, tool: String) throws
        -> MCP.Value
    {
        let payload = payloadDict(of: result)
        if result.isError == true || isExplicitError(payload) {
            guard let payload else {
                throw CuaError.malformedResponse("\(tool): error result without decodable payload")
            }
            throw mapFailure(payload)
        }
        if let structured = result.structuredContent, structured != .null {
            return structured
        }
        for block in result.content {
            if case .text(let text, _, _) = block, let data = text.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(MCP.Value.self, from: data),
                decoded != .null
            {
                return decoded
            }
        }
        throw CuaError.malformedResponse(
            "\(tool): no structuredContent and first text block is not a JSON object")
    }

    private static func requiredPayload(of result: MCP.CallTool.Result, tool: String) throws
        -> [String: MCP.Value]
    {
        let value = try anyPayload(of: result, tool: tool)
        guard case .object(let dict) = value else {
            throw CuaError.malformedResponse("\(tool): expected an object payload")
        }
        return dict
    }

    /// Detect drivers that signal failure inside a success-shaped envelope (`ok:false` or `error:`).
    private static func isExplicitError(_ payload: [String: MCP.Value]?) -> Bool {
        guard let payload else { return false }
        if case .bool(false) = payload["ok"] { return true }
        if let error = payload["error"], error != .null { return true }
        return false
    }

    // MARK: - Value accessors

    private static func schemaVersion(_ payload: [String: MCP.Value]) -> String? {
        switch payload["schema_version"] {
        case .string(let s): return s
        case .int(1): return "1"
        default: return nil
        }
    }

    /// CuaDriver 0.21 reports health facts as named check records rather than
    /// the original top-level boolean fields. Keep this translation local so
    /// the rest of the app continues to consume the frozen CuaHealth model.
    private static func healthCheckStatus(named name: String, in payload: [String: MCP.Value]) -> Bool? {
        guard case .array(let checks)? = payload["checks"] else { return nil }
        for check in checks {
            guard case .object(let dict) = check,
                string(dict["name"]) == name
            else { continue }
            switch string(dict["status"]) {
            case "pass", "passed", "ok", "granted": return true
            case "fail", "failed", "denied", "error": return false
            default: return nil
            }
        }
        return nil
    }

    /// Reads a string from a named health check, accepting both the current
    /// nested `data` object and a defensively supported direct field.
    private static func healthCheckValue(
        _ key: String,
        named name: String,
        in payload: [String: MCP.Value]
    ) -> String? {
        guard case .array(let checks)? = payload["checks"] else { return nil }
        for check in checks {
            guard case .object(let dict) = check,
                string(dict["name"]) == name
            else { continue }
            if let value = string(dict[key]) { return value }
            if case .object(let data)? = dict["data"] {
                return string(data[key])
            }
            return nil
        }
        return nil
    }

    private static func string(_ value: MCP.Value?) -> String? {
        guard case .string(let s)? = value else { return nil }
        return s
    }

    private static func int(_ value: MCP.Value?) -> Int? {
        switch value {
        case .int(let i)? : return i
        case .double(let d)?:
            // Fix #5: Int(exactly:) instead of Int(d) — an integral double
            // outside the Int range (e.g. pid=1e30) traps under Int(d); NaN/inf
            // fail exactly-conversion and return nil rather than crashing.
            return d == d.rounded() ? Int(exactly: d) : nil
        default: return nil
        }
    }

    private static func uint32(_ value: MCP.Value?) -> UInt32? {
        guard let i = int(value), i >= 0, i <= UInt32.max else { return nil }
        return UInt32(i)
    }

    private static func bool(_ value: MCP.Value?) -> Bool? {
        guard case .bool(let b)? = value else { return nil }
        return b
    }

    private static func array(_ value: MCP.Value?) -> [MCP.Value]? {
        guard case .array(let items)? = value else { return nil }
        return items
    }

    private static func rect(_ value: MCP.Value?) -> CuaRect? {
        guard case .object(let dict)? = value,
            let x = double(dict["x"]),
            let y = double(dict["y"]),
            let width = double(dict["width"]),
            let height = double(dict["height"])
        else { return nil }
        return CuaRect(x: x, y: y, width: width, height: height)
    }

    private static func double(_ value: MCP.Value?) -> Double? {
        switch value {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        default: return nil
        }
    }

    private static func describe(_ value: MCP.Value?) -> String {
        switch value {
        case .none: return "<missing>"
        case .some(let v): return String(describing: v)
        }
    }

    // MARK: - Test support

    /// Build a `CallTool.Result` from raw JSON without tests importing the MCP module directly
    /// (the test target links only Vimotion; callers rely on type inference).
    static func fixtureResult(fromJSON json: String) throws -> MCP.CallTool.Result {
        try JSONDecoder().decode(MCP.CallTool.Result.self, from: Data(json.utf8))
    }

    /// Decode a fixture and hand the result to `transform` without callers ever naming the
    /// MCP module (the test target links only Vimotion).
    static func decodingFixture<T>(
        _ json: String,
        _ transform: (MCP.CallTool.Result) throws -> T
    ) throws -> T {
        try transform(fixtureResult(fromJSON: json))
    }
}
