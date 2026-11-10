import XCTest
import UIKit
@testable import IPhoneAgent

/// The simulated endpoint never sends a real request or uses a real credential.
private final class JevStubProtocol: URLProtocol {
    enum Reply {
        case response(Int, Data)
        case failure(URLError)
        case hold
    }
    nonisolated(unsafe) static var reply = Reply.response(200, Data())
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var onStart: (() -> Void)?
    nonisolated(unsafe) static var onStop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.requests.append(request)
        Self.bodies.append(body)
        Self.onStart?()
        switch Self.reply {
        case .response(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .hold:
            break
        }
    }

    override func stopLoading() { Self.onStop?() }
}

@MainActor final class JevClientTests: XCTestCase {
    private lazy var image: Data = jpeg(width: 280, height: 280)

    private func renderer(width: Int, height: Int) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1  // fixture dimensions do not depend on simulator density
        return UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: format)
    }

    private func jpeg(width: Int, height: Int) -> Data {
        renderer(width: width, height: height).jpegData(withCompressionQuality: 0.6) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
    }

    private func session(_ reply: JevStubProtocol.Reply) -> URLSession {
        JevStubProtocol.reply = reply
        JevStubProtocol.requests = []
        JevStubProtocol.bodies = []
        JevStubProtocol.onStart = nil
        JevStubProtocol.onStop = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JevStubProtocol.self]
        return URLSession(configuration: config)
    }

    private func response(action: JevAction = .tap) -> [String: Any] {
        var probabilities = Dictionary(uniqueKeysWithValues: JevAction.allCases.map { ($0.rawValue, 0.0) })
        probabilities[action.rawValue] = 0.96
        probabilities[action == .vision ? JevAction.wait.rawValue : JevAction.vision.rawValue] = 0.04
        return [
            "model": "jev-1.14.0",
            "answers": [
                "action": ["type": "choice", "choice": action.rawValue,
                           "confidence": (0.96 - 1.0 / 8) / (1 - 1.0 / 8),
                           "probabilities": probabilities],
                "visible": ["type": "noul", "noul": 0.98],
                "safe": ["type": "noul", "noul": 0.99],
                "complete": ["type": "noul", "noul": 0.02],
                "target": ["type": "box", "box": ["left": 0.1, "top": 0.2, "right": 0.3, "bottom": 0.4],
                           "confidence": 0.93]
            ],
            "usage": ["input_tokens": 300, "output_tokens": 21]
        ]
    }

    private func data(_ response: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: response, options: .sortedKeys)
    }

    private func replacing(_ answer: String, with value: Any?, in original: [String: Any]) -> [String: Any] {
        var result = original
        var answers = result["answers"] as! [String: Any]
        answers[answer] = value
        result["answers"] = answers
        return result
    }

    private func assertInvalid(_ response: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try JevDecision.decode(data(response), seconds: 0.1), file: file, line: line) { error in
            XCTAssertEqual(error as? JevClientError, .invalidResponse, file: file, line: line)
        }
    }

    func testUsesTypeSafeProtocolAndOneSharedImageAsset() async throws {
        let transport = session(.response(200, try data(response())))
        defer { transport.invalidateAndCancel() }
        let client = JevClient(apiKey: "test-typesafe-key", session: transport)
        let screenshot = image
        let decision = try await client.decide(goal: "Open Clock", plan: "Tap Clock",
                                              history: "Home Screen", image: screenshot)
        let request = try XCTUnwrap(JevStubProtocol.requests.first)
        XCTAssertEqual(request.url, JevClient.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-typesafe-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"), "true")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(JevStubProtocol.bodies.first)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "jev-latest")
        XCTAssertNil(body["messages"])
        XCTAssertNil(body["stream"])
        let state = try XCTUnwrap(body["state"] as? [String: String])
        XCTAssertEqual(state["goal"], "Open Clock")
        XCTAssertEqual(state["plan"], "Tap Clock")
        XCTAssertEqual(state["recent_actions"], "Home Screen")
        let reference = try XCTUnwrap(state["screen"])
        XCTAssertNotNil(UUID(uuidString: reference))
        let assets = try XCTUnwrap(body["assets"] as? [String: [String: String]])
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets[reference]?["format"], "jpg")
        XCTAssertEqual(assets[reference]?["data_base64"].flatMap { Data(base64Encoded: $0) }, screenshot)
        let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
        XCTAssertEqual(Set(questions.keys), ["action", "visible", "safe", "complete", "target"])
        XCTAssertEqual(questions["action"]?["type"] as? String, "choice")
        XCTAssertEqual(questions["target"]?["type"] as? String, "box")
        XCTAssertEqual(decision.action, .tap)
        XCTAssertEqual(decision.servedModel, "jev-1.14.0")
        XCTAssertEqual(decision.usage, ["prompt_tokens": 300, "completion_tokens": 21])
        XCTAssertEqual(decision.box?.centerX ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(decision.box?.centerY ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(decision.seconds, 0)
    }

    func testBoxDoesNotImplyPresenceAndMayHaveNullConfidence() throws {
        var original = response()
        var answers = original["answers"] as! [String: Any]
        answers["visible"] = ["type": "noul", "noul": 0.01]
        var target = answers["target"] as! [String: Any]
        target["confidence"] = NSNull()
        answers["target"] = target
        original["answers"] = answers
        let result = try JevDecision.decode(data(original), seconds: 0.3)
        XCTAssertEqual(result.action, .tap)
        XCTAssertEqual(result.targetPresent, 0.01)
        XCTAssertNil(result.box?.confidence)
        XCTAssertTrue(result.box?.isValid == true)
    }

    func testRejectsPartialAnswersAndWrongQuestionTypes() throws {
        for missing in ["action", "visible", "safe", "complete"] {
            try assertInvalid(replacing(missing, with: nil, in: response()))
        }
        try assertInvalid(replacing("visible", with: ["type": "score", "noul": 0.9], in: response()))
        try assertInvalid(replacing("action", with: ["type": "choice", "choice": "purchase", "confidence": 1,
                                                   "probabilities": ["purchase": 1]], in: response()))
        try assertInvalid(replacing("action", with: ["type": "choice", "choice": "tap", "confidence": 1,
                                                   "probabilities": ["unknown": 1]], in: response()))
    }

    func testRejectsNonProbabilitiesIncludingBoolAndNonFiniteJSON() throws {
        for value in [-0.001, 1.001] {
            try assertInvalid(replacing("visible", with: ["type": "noul", "noul": value], in: response()))
        }
        try assertInvalid(replacing("safe", with: ["type": "noul", "noul": true], in: response()))
        try assertInvalid(replacing("complete", with: ["type": "noul", "noul": "NaN"], in: response()))
        try assertInvalid(replacing("action", with: ["type": "choice", "choice": "tap", "confidence": 1.1,
                                                   "probabilities": ["tap": 1]], in: response()))
        try assertInvalid(replacing("action", with: ["type": "choice", "choice": "tap", "confidence": 0.9,
                                                   "probabilities": ["tap": -0.1]], in: response()))
        let nonFinite = String(decoding: try data(response()), as: UTF8.self)
            .replacingOccurrences(of: #""noul":0.98"#, with: #""noul":NaN"#)
        XCTAssertThrowsError(try JevDecision.decode(Data(nonFinite.utf8), seconds: 1))
        XCTAssertThrowsError(try JevDecision.decode(data(response()), seconds: .infinity))
    }

    func testRejectsContradictoryChoiceAndAllowsAnHonestTie() throws {
        let base = response()
        let answers = base["answers"] as! [String: Any]
        var action = answers["action"] as! [String: Any]
        action["choice"] = "home"  // tap has 0.96, home has 0
        try assertInvalid(replacing("action", with: action, in: base))
        var uniform = Dictionary(uniqueKeysWithValues: JevAction.allCases.map { ($0.rawValue, 0.125) })
        action = ["type": "choice", "choice": "tap", "confidence": 0.99, "probabilities": uniform]
        try assertInvalid(replacing("action", with: action, in: base))  // uniform means confidence 0
        uniform = Dictionary(uniqueKeysWithValues: JevAction.allCases.map { ($0.rawValue, 0.0) })
        uniform["tap"] = 0.5
        uniform["home"] = 0.5
        action = ["type": "choice", "choice": "tap", "confidence": (0.5 - 0.125) / 0.875,
                  "probabilities": uniform]
        let tied = try JevDecision.decode(data(replacing("action", with: action, in: base)), seconds: 0.1)
        XCTAssertEqual(tied.action, .tap)
        XCTAssertLessThan(tied.confidence, 0.5)  // a tie is valid evidence for a fallback, not certainty
    }

    func testRejectsInvalidBoxAndTapWithoutBox() throws {
        let invalid: [[String: Double]] = [
            ["left": -0.1, "top": 0.2, "right": 0.3, "bottom": 0.4],
            ["left": 0.4, "top": 0.2, "right": 0.3, "bottom": 0.4],
            ["left": 0.1, "top": 0.2, "right": 0.1, "bottom": 0.4],
            ["left": 0.1, "top": 0.5, "right": 0.3, "bottom": 0.4],
            ["left": 0.1, "top": 0.2, "right": 0.3, "bottom": 1.01]
        ]
        for box in invalid {
            try assertInvalid(replacing("target", with: ["type": "box", "box": box, "confidence": 0.99], in: response()))
        }
        try assertInvalid(replacing("target", with: nil, in: response()))
        try assertInvalid(replacing("target", with: ["type": "box", "box": ["left": 0.1, "top": 0.2, "right": 0.3, "bottom": 0.4],
                                                    "confidence": 1.01], in: response()))
    }

    func testNonTapMayReturnNoBox() throws {
        let result = try JevDecision.decode(data(replacing("target", with: nil, in: response(action: .home))), seconds: 1)
        XCTAssertEqual(result.action, .home)
        XCTAssertNil(result.box)
    }

    func testHTTPFailureIsNotRetriedAndDoesNotExposeServerContent() async throws {
        let secret = "server echoed private-key-and-screen-content"
        let transport = session(.response(429, Data(secret.utf8)))
        defer { transport.invalidateAndCancel() }
        do {
            _ = try await JevClient(apiKey: "test-key", session: transport)
                .decide(goal: "Open Clock", plan: "", history: "", image: image)
            XCTFail("Accepted HTTP error")
        } catch {
            XCTAssertEqual(error as? JevClientError, .httpStatus(429))
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
        XCTAssertEqual(JevStubProtocol.requests.count, 1)
    }

    func testTransportFailureIsNotRetried() async throws {
        let transport = session(.failure(URLError(.timedOut)))
        defer { transport.invalidateAndCancel() }
        do {
            _ = try await JevClient(apiKey: "test-key", session: transport)
                .decide(goal: "Open Clock", plan: "", history: "", image: image)
            XCTFail("Accepted timeout")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(JevStubProtocol.requests.count, 1)
    }

    func testCancellationStopsHeldRequest() async throws {
        let transport = session(.hold)
        defer { transport.invalidateAndCancel() }
        let began = expectation(description: "request started")
        let stopped = expectation(description: "request stopped")
        JevStubProtocol.onStart = { began.fulfill() }
        JevStubProtocol.onStop = { stopped.fulfill() }
        let client = JevClient(apiKey: "test-key", session: transport)
        let task = Task { try await client.decide(goal: "Open Clock", plan: "", history: "", image: image) }
        await fulfillment(of: [began], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation was ignored") }
        catch is CancellationError {}
        catch { XCTFail("Expected cancellation, got \(error)") }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(JevStubProtocol.requests.count, 1)
    }

    func testInvalidConfigurationAndOversizeImageSendNothing() async throws {
        let transport = session(.hold)
        defer { transport.invalidateAndCancel() }
        let missing = JevClient(apiKey: "  ", session: transport)
        do { _ = try await missing.decide(goal: "x", plan: "", history: "", image: image); XCTFail("Missing key") }
        catch { XCTAssertEqual(error as? JevClientError, .missingKey) }
        let invalid = JevClient(model: "", apiKey: "test", session: transport)
        do { _ = try await invalid.decide(goal: "x", plan: "", history: "", image: image); XCTFail("Missing model") }
        catch { XCTAssertEqual(error as? JevClientError, .invalidRequest) }
        let injected = JevClient(apiKey: "test\nheader", session: transport)
        do { _ = try await injected.decide(goal: "x", plan: "", history: "", image: image); XCTFail("Invalid header") }
        catch { XCTAssertEqual(error as? JevClientError, .invalidRequest) }
        let client = JevClient(apiKey: "test", session: transport)
        do {
            _ = try await client.decide(goal: "x", plan: "", history: "",
                                        image: Data(repeating: 0, count: 16 * 1024 * 1024 + 1))
            XCTFail("Oversize image")
        } catch { XCTAssertEqual(error as? JevClientError, .invalidRequest) }
        XCTAssertTrue(JevStubProtocol.requests.isEmpty)
    }

    func testImageDimensionsAndRealJPEGAreCheckedBeforeSending() async throws {
        let transport = session(.hold)
        defer { transport.invalidateAndCancel() }
        let client = JevClient(apiKey: "test", session: transport)
        let png = renderer(width: 280, height: 280).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 280, height: 280))
        }
        let invalid = [
            jpeg(width: 1569, height: 280),
            jpeg(width: 280, height: 1569),
            jpeg(width: 279, height: 280),
            jpeg(width: 280, height: 279),
            png,
            Data([0xff, 0xd8, 0xff, 0xd9]),
            Data("not an image".utf8)
        ]
        for screenshot in invalid {
            do {
                _ = try await client.decide(goal: "Open Clock", plan: "", history: "", image: screenshot)
                XCTFail("Accepted a screenshot outside the JPEG contract")
            } catch { XCTAssertEqual(error as? JevClientError, .invalidRequest) }
        }
        XCTAssertTrue(JevStubProtocol.requests.isEmpty)
    }

    func testMaximumJPEGDimensionsAreAccepted() async throws {
        let transport = session(.response(200, try data(response())))
        defer { transport.invalidateAndCancel() }
        _ = try await JevClient(apiKey: "test", session: transport)
            .decide(goal: "Open Clock", plan: "", history: "", image: jpeg(width: 1568, height: 1568))
        XCTAssertEqual(JevStubProtocol.requests.count, 1)
    }

    func testInjectedSessionRemainsUsableAfterClientIsReleased() async throws {
        let transport = session(.response(200, try data(response())))
        defer { transport.invalidateAndCancel() }
        var client: JevClient? = JevClient(apiKey: "test", session: transport)
        _ = try await client?.decide(goal: "Open Clock", plan: "", history: "", image: image)
        client = nil
        _ = try await JevClient(apiKey: "test", session: transport)
            .decide(goal: "Open Clock", plan: "", history: "", image: image)
        XCTAssertEqual(JevStubProtocol.requests.count, 2)
    }

    func testRejectsMalformedJSONAndOversizeResponse() async throws {
        for reply in [Data("not JSON".utf8), Data(repeating: 32, count: 1_048_577)] {
            let transport = session(.response(200, reply))
            defer { transport.invalidateAndCancel() }
            do {
                _ = try await JevClient(apiKey: "test", session: transport)
                    .decide(goal: "Open Clock", plan: "", history: "", image: image)
                XCTFail("Accepted invalid response")
            } catch { XCTAssertEqual(error as? JevClientError, .invalidResponse) }
        }
    }
}
