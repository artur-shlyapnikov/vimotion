// CuaResponseDecoderTests.swift — pure fixture tests for CuaResponseDecoder.
// No subprocess involved. The test target does NOT link MCP; results are built
// through CuaResponseDecoder.decodingFixture so the MCP module is never named here.

import XCTest
@testable import Vimotion

final class CuaResponseDecoderTests: XCTestCase {
    // MARK: - Fixtures

    private static let healthFixture =
        #"{"content":[],"structuredContent":{"schema_version":1,"binary_version":"0.4.2","platform_supported":true,"session_active":false,"bundle_identity":"local.cua.CuaDriver","tcc_accessibility":true,"ax_capability":true,"some_future_check":{"whatever":true}},"isError":false}"#

    private static let healthStringSchemaFixture =
        #"{"content":[],"structuredContent":{"schema_version":"1","binary_version":"0.4.2"},"isError":false}"#

    private static let healthChecksFixture =
        #"{"content":[],"structuredContent":{"schema_version":"1","driver_version":"0.21.0","platform":"darwin","overall":"ok","checks":[{"name":"binary_version","status":"pass","message":"cua-driver 0.21.0"},{"name":"platform_supported","status":"pass"},{"name":"session_active","status":"pass"},{"name":"bundle_identity","status":"pass","data":{"bundle_identifier":"com.trycua.driver"}},{"name":"tcc_accessibility","status":"pass"},{"name":"ax_capability","status":"pass"}]},"isError":false}"#

    private static let windowsFixture =
        #"{"content":[],"structuredContent":{"windows":[{"window_id":730,"pid":284,"app_name":"Finder","title":null,"bounds":{"x":0,"y":25,"width":1440,"height":900},"z_index":12,"is_on_screen":true,"on_current_space":true},{"window_id":901,"pid":512,"bounds":{"x":10,"y":20,"width":800,"height":600}}]},"isError":false}"#

    private static let snapshotFixture =
        #"{"content":[],"structuredContent":{"snapshot_id":"snap-42","window_bounds":{"x":0,"y":25,"width":1440,"height":900},"elements":[{"element_index":0,"element_token":"tok-abc","role":"AXButton","label":"OK","value":null,"frame":{"x":100,"y":200,"width":80,"height":24}},{"index":1,"token":"tok-def","role":"AXTextField","label":null,"value":"hello","frame":{"x":5,"y":6,"width":7,"height":8},"parent_index":0,"depth":2}],"element_count":2},"isError":false}"#

    // MARK: - Helpers

    /// Asserts that decoding a fixture through `decode` throws exactly `expected`.
    private func assertError<T>(
        _ json: String,
        _ decode: @escaping (String) throws -> T,
        matches expected: @autoclosure () -> CuaError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try decode(json)
            XCTFail("expected \(expected())", file: file, line: line)
        } catch let error as CuaError {
            XCTAssertEqual(error, expected(), file: file, line: line)
        } catch {
            XCTFail("unexpected error type \(error)", file: file, line: line)
        }
    }

    private func assertMalformedHealth(
        _ json: String, prefix: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            _ = try CuaResponseDecoder.decodingFixture(json) {
                try CuaResponseDecoder.health(from: $0)
            }
            XCTFail("expected malformedResponse", file: file, line: line)
        } catch let error as CuaError {
            guard case .malformedResponse(let detail) = error else {
                XCTFail("expected .malformedResponse, got \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue(detail.hasPrefix(prefix), "got: \(detail)", file: file, line: line)
        } catch {
            XCTFail("unexpected error type \(error)", file: file, line: line)
        }
    }

    private func health(_ json: String) throws -> CuaHealth {
        try CuaResponseDecoder.decodingFixture(json) { try CuaResponseDecoder.health(from: $0) }
    }

    private func windows(_ json: String) throws -> [CuaWindow] {
        try CuaResponseDecoder.decodingFixture(json) { try CuaResponseDecoder.windows(from: $0) }
    }

    private func snapshot(_ json: String) throws -> CuaWindowSnapshot {
        try CuaResponseDecoder.decodingFixture(json) {
            try CuaResponseDecoder.snapshot(pid: 284, windowID: 730, from: $0)
        }
    }

    private func click(_ json: String) throws {
        try CuaResponseDecoder.decodingFixture(json) {
            try CuaResponseDecoder.clickAcknowledgement(from: $0)
        }
    }

    // MARK: - health_report

    func testHealthAcceptsIntegerSchemaVersion() throws {
        XCTAssertEqual(
            try health(Self.healthFixture),
            CuaHealth(
                schemaVersion: "1",
                binaryVersion: "0.4.2",
                platformSupported: true,
                sessionActive: false,
                bundleIdentity: "local.cua.CuaDriver",
                tccAccessibility: true,
                axCapability: true
            ))
    }

    func testHealthAcceptsStringSchemaVersion() throws {
        let parsed = try health(Self.healthStringSchemaFixture)
        XCTAssertEqual(parsed.schemaVersion, "1")
        XCTAssertNil(parsed.platformSupported)
    }

    func testHealthAcceptsNamedChecksFormat() throws {
        XCTAssertEqual(
            try health(Self.healthChecksFixture),
            CuaHealth(
                schemaVersion: "1",
                binaryVersion: "0.21.0",
                platformSupported: true,
                sessionActive: true,
                bundleIdentity: "com.trycua.driver",
                tccAccessibility: true,
                axCapability: true
            ))
    }

    func testHealthRejectsWrongSchemaVersion() {
        assertMalformedHealth(
            #"{"content":[],"structuredContent":{"schema_version":"2"},"isError":false}"#,
            prefix: "health_report: unsupported schema_version")
    }

    // MARK: - list_windows

    func testListWindowsUnrepresentableDoublePIDIsMalformed() {
        // pid 1e30 decodes as .double; Int(exactly:) must fail it → "missing pid",
        // never an Int(d) trap.
        assertError(
            #"{"content":[],"structuredContent":{"windows":[{"window_id":1,"pid":1e30,"bounds":{"x":0,"y":0,"width":1,"height":1}}]},"isError":false}"#,
            { try self.windows($0) },
            matches: CuaError.malformedResponse("list_windows: window #0 missing pid"))
    }

    func testListWindowsIntegralDoublePIDDecodes() throws {
        let json =
            #"{"content":[],"structuredContent":{"windows":[{"window_id":730,"pid":284.0,"bounds":{"x":0,"y":25,"width":1440,"height":900}}]},"isError":false}"#
        let parsed = try windows(json)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].pid, 284)
    }

    func testListWindowsDecodesFullAndSparseEntries() throws {
        let parsed = try windows(Self.windowsFixture)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(
            parsed[0],
            CuaWindow(
                windowID: 730, pid: 284, appName: "Finder", title: nil,
                bounds: CuaRect(x: 0, y: 25, width: 1440, height: 900),
                zIndex: 12, isOnScreen: true, onCurrentSpace: true))
        XCTAssertEqual(
            parsed[1],
            CuaWindow(
                windowID: 901, pid: 512, appName: nil, title: nil,
                bounds: CuaRect(x: 10, y: 20, width: 800, height: 600),
                zIndex: nil, isOnScreen: false, onCurrentSpace: false))
    }

    func testListWindowsAcceptsBareArrayPayload() throws {
        let json =
            #"{"content":[],"structuredContent":[{"window_id":1,"pid":2,"bounds":{"x":0,"y":0,"width":1,"height":1},"is_on_screen":true,"on_current_space":false}],"isError":false}"#
        let parsed = try windows(json)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].windowID, 1)
    }

    func testListWindowsMissingWindowIDIsMalformed() {
        assertError(
            #"{"content":[],"structuredContent":{"windows":[{"pid":2,"bounds":{"x":0,"y":0,"width":1,"height":1}}]},"isError":false}"#,
            { try self.windows($0) },
            matches: CuaError.malformedResponse("list_windows: window #0 missing window_id"))
    }

    // MARK: - get_window_state

    func testSnapshotDecodesCanonicalAndAlternativeSpellings() throws {
        let parsed = try snapshot(Self.snapshotFixture)
        XCTAssertEqual(parsed.pid, 284)
        XCTAssertEqual(parsed.windowID, 730)
        XCTAssertEqual(parsed.snapshotID, "snap-42")
        XCTAssertEqual(parsed.windowBounds.width, 1440)
        XCTAssertEqual(parsed.elementCount, 2)
        XCTAssertNil(parsed.degradedReason)
        XCTAssertFalse(parsed.offSpace)

        XCTAssertEqual(parsed.elements[0].index, 0)
        XCTAssertEqual(parsed.elements[0].token, "tok-abc")
        XCTAssertEqual(parsed.elements[0].role, "AXButton")
        XCTAssertEqual(parsed.elements[0].label, "OK")
        XCTAssertNil(parsed.elements[0].parentIndex)
        XCTAssertEqual(parsed.elements[0].depth, 0)

        XCTAssertEqual(parsed.elements[1].index, 1)
        XCTAssertEqual(parsed.elements[1].token, "tok-def")
        XCTAssertEqual(parsed.elements[1].parentIndex, 0)
        XCTAssertEqual(parsed.elements[1].depth, 2)
        XCTAssertEqual(parsed.elements[1].value, "hello")
    }

    func testSnapshotWithMissingElementTokenIsMalformed() {
        assertError(
            #"{"content":[],"structuredContent":{"window_bounds":{"x":0,"y":0,"width":1,"height":1},"elements":[{"element_index":0,"role":"AXButton","frame":{"x":0,"y":0,"width":1,"height":1}}]},"isError":false}"#,
            { try self.snapshot($0) },
            matches: CuaError.malformedResponse("get_window_state: element #0 missing token"))
    }

    func testSnapshotWithoutElementsArrayIsMalformed() {
        assertError(
            #"{"content":[],"structuredContent":{"window_bounds":{"x":0,"y":0,"width":1,"height":1}},"isError":false}"#,
            { try self.snapshot($0) },
            matches: CuaError.malformedResponse("get_window_state: missing elements array"))
    }

    func testSnapshotDegradedAxWindowUnresolvedMapsToTypedFailure() {
        assertError(
            #"{"content":[],"structuredContent":{"window_bounds":{"x":0,"y":0,"width":1,"height":1},"elements":[],"degraded_reason":"ax_window_unresolved"},"isError":false}"#,
            { try self.snapshot($0) },
            matches: CuaError.axWindowUnresolved)
    }

    func testSnapshotOtherDegradedReasonIsTolerated() throws {
        let parsed = try snapshot(
            #"{"content":[],"structuredContent":{"window_bounds":{"x":0,"y":0,"width":1,"height":1},"elements":[],"degraded_reason":"truncated_tree","off_space":true,"element_count":0},"isError":false}"#)
        XCTAssertEqual(parsed.degradedReason, "truncated_tree")
        XCTAssertTrue(parsed.offSpace)
    }

    func testSnapshotFractionalDoubleInOptionalIntegerFieldToleratedAsNil() throws {
        // parent_index 12.5 fails exactly-conversion in int(); the optional
        // field tolerates that as nil instead of trapping or throwing.
        let json =
            #"{"content":[],"structuredContent":{"snapshot_id":"snap-42","window_bounds":{"x":0,"y":25,"width":1440,"height":900},"elements":[{"element_index":0,"element_token":"tok-abc","role":"AXButton","frame":{"x":100,"y":200,"width":80,"height":24},"parent_index":12.5}],"element_count":1},"isError":false}"#
        let parsed = try snapshot(json)
        XCTAssertEqual(parsed.elements.count, 1)
        XCTAssertEqual(parsed.elements[0].index, 0)
        XCTAssertNil(parsed.elements[0].parentIndex)
    }

    // MARK: - click

    func testClickOkTrueSucceeds() throws {
        XCTAssertNoThrow(try click(#"{"content":[],"structuredContent":{"ok":true},"isError":false}"#))
    }

    func testClickEmptyObjectAndNullPayloadSucceed() throws {
        XCTAssertNoThrow(try click(#"{"content":[],"structuredContent":{},"isError":false}"#))
        XCTAssertNoThrow(try click(#"{"content":[],"structuredContent":null,"isError":false}"#))
    }

    // MARK: - Typed failure mapping

    func testWindowNotFoundMapping() {
        assertError(
            #"{"content":[],"structuredContent":{"code":"window_id_not_found","message":"no such window"},"isError":true}"#,
            { try self.snapshot($0) },
            matches: CuaError.windowNotFound)
    }

    func testOwnerMismatchCarriesActualPID() {
        assertError(
            #"{"content":[],"structuredContent":{"code":"window_owner_pid_mismatch","actual_pid":4711,"message":"owned by 4711"},"isError":true}"#,
            { try self.snapshot($0) },
            matches: CuaError.windowOwnerMismatch(actualPID: 4711))
    }

    func testOwnerMismatchCamelCaseActualPIDAlsoAccepted() {
        assertError(
            #"{"content":[],"structuredContent":{"code":"window_owner_pid_mismatch","actualPID":99,"message":"mismatch"},"isError":true}"#,
            { try self.snapshot($0) },
            matches: CuaError.windowOwnerMismatch(actualPID: 99))
    }

    func testOwnerMismatchWithoutActualPIDDefaultsToMinusOne() {
        assertError(
            #"{"content":[],"structuredContent":{"code":"window_owner_pid_mismatch","message":"mismatch"},"isError":true}"#,
            { try self.snapshot($0) },
            matches: CuaError.windowOwnerMismatch(actualPID: -1))
    }

    func testStaleTokenMapping() {
        assertError(
            #"{"content":[],"structuredContent":{"code":"stale_element_token","message":"snapshot superseded"},"isError":true}"#,
            { try self.click($0) },
            matches: CuaError.staleElementToken)
    }

    func testAccessibilityAndTCCCodesMapToDenied() {
        for code in ["tcc_denied", "accessibility_not_trusted"] {
            let json =
                #"{"content":[],"structuredContent":{"code":"\#(code)","message":"denied"},"isError":true}"#
            assertError(
                json,
                { try self.click($0) },
                matches: CuaError.accessibilityDenied)
        }
    }

    func testUnknownCodeFallsBackToToolRejected() {
        assertError(
            #"{"content":[],"structuredContent":{"code":"weird_failure","message":"boom"},"isError":true}"#,
            { try self.click($0) },
            matches: CuaError.toolRejected(code: "weird_failure", message: "boom"))
    }

    func testFailureSignaledViaOkFalseWithoutIsErrorFlag() {
        assertError(
            #"{"content":[],"structuredContent":{"ok":false,"code":"window_id_not_found","message":"gone"},"isError":false}"#,
            { try self.click($0) },
            matches: CuaError.windowNotFound)
    }

    func testFailureSignaledViaErrorKeyWithoutIsErrorFlag() {
        assertError(
            #"{"content":[],"structuredContent":{"error":"stale_element_token","message":"superseded"},"isError":false}"#,
            { try self.click($0) },
            matches: CuaError.staleElementToken)
    }

    // MARK: - Nested error envelope

    func testNestedErrorEnvelopeMapsTypedFailures() {
        assertError(
            #"{"content":[],"structuredContent":{"error":{"code":"window_id_not_found","message":"no such window"}},"isError":true}"#,
            { try self.snapshot($0) },
            matches: CuaError.windowNotFound)
    }

    func testNestedStaleElementTokenEnvelopeMapsTypedFailure() {
        assertError(
            #"{"content":[],"structuredContent":{"error":{"code":"stale_element_token","message":"snapshot superseded"}},"isError":true}"#,
            { try self.click($0) },
            matches: CuaError.staleElementToken)
    }

    func testNestedOwnerMismatchEnvelopeCarriesActualPID() {
        assertError(
            #"{"content":[],"structuredContent":{"error":{"code":"window_owner_pid_mismatch","actual_pid":4711,"message":"owned by 4711"}},"isError":true}"#,
            { try self.snapshot($0) },
            matches: CuaError.windowOwnerMismatch(actualPID: 4711))
    }

    func testNestedUnknownCodeFallsBackToToolRejected() {
        assertError(
            #"{"content":[],"structuredContent":{"error":{"code":"weird_failure","message":"boom"}},"isError":true}"#,
            { try self.click($0) },
            matches: CuaError.toolRejected(code: "weird_failure", message: "boom"))
    }

    func testTextFallbackParsesFirstTextBlockAsJSONObject() throws {
        // No structuredContent: decoder must fall back to the first `.text` content block.
        let payload = #"{"code":"window_id_not_found","message":"gone"}"#
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = #"{"content":[{"type":"text","text":"\#(payload)"}],"isError":true}"#
        assertError(
            json,
            { try self.snapshot($0) },
            matches: CuaError.windowNotFound)
    }

    // MARK: - Malformed variants

    func testNonDictStructuredContentWithUnparseableTextIsMalformed() {
        assertMalformedHealth(
            #"{"content":[{"type":"text","text":"not json at all"}],"structuredContent":"just a string","isError":false}"#,
            prefix: "health_report:")
    }

    func testErrorResultWithoutDecodablePayloadIsMalformed() {
        assertMalformedHealth(
            #"{"content":[{"type":"text","text":"<binary garbage>"}],"isError":true}"#,
            prefix: "health_report: error result without decodable payload")
    }
}
