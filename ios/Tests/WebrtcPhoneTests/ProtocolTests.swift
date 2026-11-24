import XCTest
@testable import WebrtcPhone

/// 逐字节协议对齐测试（对齐 Android 端对应单测）。
final class ProtocolTests: XCTestCase {

    // MARK: - 信令
    func testConnectMessage() {
        let s = SignalingProtocol.connect("dev-123")
        let o = parse(s)
        XCTAssertEqual(o?["message_type"] as? String, "connect")
        XCTAssertEqual(o?["device_id"] as? String, "dev-123")
    }

    func testRequestOfferIncludesScrcpyOptionsAndNoNullResumeKey() throws {
        let endpoint = try XCTUnwrap(ServerEndpoint.parse("192.168.1.2"))
        let target = StreamTarget(endpoint: endpoint, deviceId: "d1", deviceName: "D", auth: .user(token: "t"))
        let s = SignalingProtocol.requestOffer("d1", options: ScrcpyOptions.build(target), resumeKey: nil)
        let o = parse(s)
        XCTAssertEqual(o?["message_type"] as? String, "forward")
        let payload = o?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["type"] as? String, "request-offer")
        XCTAssertEqual(payload?["ip_preference"] as? String, "auto")
        XCTAssertNil(payload?["projection_resume_key"])
        let opts = payload?["scrcpy_options"] as? [String: Any]
        XCTAssertEqual(opts?["video_source"] as? String, "display")
    }

    func testCameraRequestOfferSendsCameraSource() throws {
        let endpoint = try XCTUnwrap(ServerEndpoint.parse("host:8443"))
        var target = StreamTarget(endpoint: endpoint, deviceId: "d", deviceName: "D", auth: .user(token: "t"))
        target.mode = .camera(CameraParams())
        let opts = ScrcpyOptions.build(target)
        XCTAssertEqual(opts["video_source"] as? String, "camera")
        XCTAssertEqual(opts["audio_source"] as? String, "mic")
    }

    func testCandidateParseBothMidKeys() {
        let text = #"{"message_type":"device_msg","payload":{"type":"ice-candidate","candidate":{"candidate":"candidate:1","sdpMLineIndex":0,"mid":"0"}}}"#
        guard case .candidate(let c) = SignalingProtocol.parse(text) else {
            return XCTFail("expected candidate")
        }
        XCTAssertEqual(c.candidate, "candidate:1")
        XCTAssertEqual(c.sdpMid, "0")
        XCTAssertEqual(c.sdpMLineIndex, 0)
    }

    // MARK: - 输入协议
    func testTouchClampsToFrame() {
        var sent: [String] = []
        let p = InputProtocol(sender: { s in sent.append(s); return true }, viewOnly: { false }, clock: { 100 })
        _ = p.touch(pointerId: 0, action: TouchAction.down, x: 5000, y: -3, w: 1000, h: 800)
        let o = parse(sent.first ?? "")
        XCTAssertEqual(o?["x"] as? Int, 1000)
        XCTAssertEqual(o?["y"] as? Int, 0)
        XCTAssertEqual(o?["type"] as? String, "touch")
        XCTAssertEqual(o?["client_ts_ms"] as? Int, 100)
    }

    func testViewOnlyBlocksTouch() {
        var sent: [String] = []
        let p = InputProtocol(sender: { s in sent.append(s); return true }, viewOnly: { true })
        XCTAssertFalse(p.touch(pointerId: 0, action: TouchAction.down, x: 1, y: 1, w: 10, h: 10))
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - 剪贴板
    func testClipboardLoopPrevention() {
        var sent: [String] = []
        let p = ClipboardProtocol(sender: { s in sent.append(s); return true }, enabled: { true })
        XCTAssertTrue(p.setClipboard("hello"))
        XCTAssertFalse(p.setClipboard("hello")) // 防回环
        XCTAssertNil(p.parseIncoming(#"{"type":"clipboard","text":"hello","source":"local"}"#))
        XCTAssertNil(p.parseIncoming(#"{"type":"clipboard","text":"kbd","source":"keyboard"}"#))
        XCTAssertEqual(p.parseIncoming(#"{"type":"clipboard","text":"remote","source":"remote"}"#), "remote")
    }

    // MARK: - WS PREV 头
    func testPrevFrameParse() {
        var bytes = [UInt8](repeating: 0, count: 49)
        bytes[0] = 0x50; bytes[1] = 0x52; bytes[2] = 0x45; bytes[3] = 0x56
        let id = Array("dev1".utf8)
        for (i, b) in id.enumerated() { bytes[4 + i] = b }
        bytes[36] = 1
        // pts = 0x0102030405060708
        let pts: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        for (i, b) in pts.enumerated() { bytes[37 + i] = b }
        // len = 2
        bytes[48] = 2
        bytes.append(contentsOf: [0x67, 0x68])
        let frame = WsProtocol.parsePrev(Data(bytes))
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.deviceId, "dev1")
        XCTAssertEqual(frame?.isKey, true)
        XCTAssertEqual(frame?.ptsUs, 0x0102030405060708)
        XCTAssertEqual(frame?.nalu, Data([0x67, 0x68]))
    }

    // MARK: - ServerEndpoint
    func testEndpointParsing() throws {
        XCTAssertEqual(ServerEndpoint.parse("192.168.1.2")?.port, 8443)
        XCTAssertEqual(ServerEndpoint.parse("192.168.1.2")?.secure, true)
        XCTAssertEqual(ServerEndpoint.parse("http://[::1]:9000/")?.host, "::1")
        XCTAssertNil(ServerEndpoint.parse("https://user:pass@host"))
    }

    // MARK: - 终端
    func testTerminalInitFrame() {
        var sent: [Data] = []
        let t = TerminalChannel { d in sent.append(d); return true }
        XCTAssertTrue(t.start(rows: 24, cols: 80))
        let o = parse(sent.first ?? Data())
        XCTAssertEqual(o?["type"] as? String, "init")
        XCTAssertEqual(o?["rows"] as? Int, 24)
    }

    // MARK: - helpers
    private func parse(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    private func parse(_ d: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
