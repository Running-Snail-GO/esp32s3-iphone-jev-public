import XCTest
@testable import IPhoneAgent

@MainActor final class JevAgentTests: XCTestCase {
    private func decision(_ action: JevAction = .tap, confidence: Double = 0.98,
                          present: Double = 0.98, safe: Double = 0.98, complete: Double? = nil,
                          box: JevBox? = JevBox(left: 0.1, top: 0.2, right: 0.3, bottom: 0.4, confidence: 0.97)) -> JevDecision {
        JevDecision(action: action, confidence: confidence, targetPresent: present,
                    safeToAct: safe, goalComplete: complete ?? (action == .done ? 0.99 : 0),
                    box: box, seconds: 0.12, usage: ["prompt_tokens": 11, "completion_tokens": 3])
    }

    func testConfidentJevTapUsesExistingPointerAndSkipsVisionActor() async throws {
        let phone = FakeGestures(), actor = FakeModel { _ in "DO: tap 900 900" }
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: actor, planner: nil, trace: nil)
        agent.jev = StubJev { self.decision() }
        var calls: [ModelCall] = []
        agent.onModelCall = { calls.append($0) }
        _ = try await agent.step()
        XCTAssertTrue(actor.prompts.isEmpty)
        XCTAssertEqual(phone.taps.count, 1)
        XCTAssertEqual(phone.taps[0].x, 0.2, accuracy: 0.001)
        XCTAssertEqual(phone.taps[0].y, 0.3, accuracy: 0.001)
        XCTAssertEqual(agent.steps.last?["executor"], .str("jev"))
        XCTAssertEqual(calls.map(\.role), ["jev"])
        XCTAssertEqual(calls.first?.reply?.usage["prompt_tokens"], 11)
    }

    func testAbsentTargetLowConfidenceOrSensitiveStepUsesVisionActor() async throws {
        for result in [decision(present: 0.1), decision(confidence: 0.4), decision(safe: 0.1),
                       decision(.vision), decision(.done), decision(.tap, complete: 0.99)] {
            let actor = FakeModel { _ in "DO: wait" }
            let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: actor, planner: nil, trace: nil)
            agent.jev = StubJev { result }
            let acts = try await agent.nextActions()
            XCTAssertEqual(acts.first?.act["action"], .str("wait"))
            XCTAssertEqual(actor.prompts.count, 1)
        }
    }

    func testCompletionIsConfirmedByVisionRatherThanTrustingJevDone() async throws {
        let actor = FakeModel { _ in "DO: done Clock shows 07:00 every day" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: actor, planner: nil, trace: nil)
        agent.jev = StubJev { self.decision(.done) }
        let finished = try await agent.step()
        XCTAssertTrue(finished)
        XCTAssertEqual(actor.prompts.count, 1)
        XCTAssertEqual(agent.steps.last?["answer"], .str("Clock shows 07:00 every day"))
    }

    func testServiceFailureFallsBackAndDisablesFurtherRequestsForTheRun() async throws {
        let jev = StubJev { throw JevClientError.httpStatus(503) }
        let actor = FakeModel { _ in "DO: wait" }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: actor, planner: nil, trace: nil)
        agent.jev = jev
        _ = try await agent.nextActions()
        _ = try await agent.nextActions()
        XCTAssertEqual(jev.calls, 1)
        XCTAssertEqual(actor.prompts.count, 2)
    }

    func testReconnectDuringJevDiscardsCoordinatesAndRestoresBeforeVisionFallback() async throws {
        let phone = FakeGestures(), screen = FakeScreen(), actor = FakeModel { _ in "DO: tap 700 800" }
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: nil, trace: nil)
        agent.jev = StubJev { device.links += 1; return self.decision() }
        var restored = 0
        agent.restore = { restored += 1; screen.frame = Data([3]); screen.updated = now() }
        _ = try await agent.step()
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(phone.taps, [CGPoint(x: 0.7, y: 0.8)])
        XCTAssertEqual(actor.images, [Data([3])])
    }

    func testCancellationNeverFallsBackOrTaps() async throws {
        let actor = FakeModel { _ in "DO: tap 900 900" }, phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: actor, planner: nil, trace: nil)
        agent.jev = StubJev { throw CancellationError() }
        do { _ = try await agent.nextActions(); XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(actor.prompts.isEmpty)
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testRestorationRechecksGateAndRejectsAnotherReconnectBeforeJevRequest() async throws {
        let phone = FakeGestures(), screen = FakeScreen(), actor = FakeModel { _ in "DO: tap 700 800" }
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: nil, trace: nil)
        let jev = StubJev { self.decision() }
        agent.jev = jev
        _ = try await agent.ask("planner", FakeModel { _ in "observe" }, "", "")
        device.links += 1
        screen.live = false
        agent.link = { Recovery.Link(connected: true, sta: 1, ap: "streaming", frameAt: now()) }
        var restored = 0, gates = 0
        agent.restore = {
            restored += 1
            screen.live = true
            screen.frame = Data([UInt8(restored)])
            screen.updated = now()
        }
        agent.gate = {
            gates += 1
            if gates == 2 { device.links += 1 }
        }
        _ = try await agent.step()
        XCTAssertEqual(jev.calls, 0)
        XCTAssertEqual(restored, 2)
        XCTAssertEqual(actor.images, [Data([2])])
        XCTAssertEqual(phone.taps, [CGPoint(x: 0.7, y: 0.8)])
    }

    func testActionGateReconnectStillRejectsPreviouslyAcceptedJevCoordinates() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let device = try XCTUnwrap(phone.device as? FakeDevice)
        let actor = FakeModel { _ in "DO: done already complete" }
        let planner = FakeModel { _ in "1. Observe the current screen" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: planner, trace: nil)
        var decisions = 0
        let jev = StubJev { decisions += 1; return self.decision(decisions == 1 ? .tap : .done) }
        agent.jev = jev
        var gates = 0, restored = 0
        agent.gate = { gates += 1; if gates == 3 { device.links += 1 } } // planner, Jev, action
        agent.restore = { restored += 1; screen.frame = Data([4]); screen.updated = now() }
        await agent.run()
        XCTAssertEqual(jev.calls, 2)
        XCTAssertEqual(restored, 1)
        XCTAssertTrue(phone.taps.isEmpty)
        XCTAssertEqual(planner.prompts.count, 2)
        XCTAssertEqual(agent.steps.last?["action"], .str("done"))
    }

    func testUnchangedJevTapFallsBackAcrossExecutorMetadata() async throws {
        let actor = FakeModel { _ in "DO: home" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: actor, planner: nil, trace: nil)
        agent.jev = StubJev { self.decision() }
        agent.steps = [["action": .str("tap"), "x": .int(200), "y": .int(300),
                        "executor": .str("jev"), "changed": .bool(false)]]
        let actions = try await agent.nextActions()
        XCTAssertEqual(actions.first?.act["action"], .str("home"))
        XCTAssertEqual(actor.prompts.count, 1)
    }

    func testPolicyRejectsMalformedOrOversizedTargetsAndPreservesScrollDirection() {
        XCTAssertNil(JevPolicy.action(for: decision(box: JevBox(left: 0, top: 0, right: 1, bottom: 1, confidence: 1)), minConfidence: 0.85))
        XCTAssertNil(JevPolicy.action(for: decision(confidence: .nan), minConfidence: 0.85))
        XCTAssertNil(JevPolicy.action(for: decision(), minConfidence: .nan))
        let up = JevPolicy.action(for: decision(.scrollUp, box: nil), minConfidence: 0.85)
        let down = JevPolicy.action(for: decision(.scrollDown, box: nil), minConfidence: 0.85)
        XCTAssertEqual(up?["y1"], .int(350)); XCTAssertEqual(up?["y2"], .int(600))
        XCTAssertEqual(down?["y1"], .int(650)); XCTAssertEqual(down?["y2"], .int(400))
    }
}

@MainActor private final class StubJev: JevDeciding {
    let model = "jev-test"
    private(set) var calls = 0
    private let reply: () throws -> JevDecision
    init(_ reply: @escaping () throws -> JevDecision) { self.reply = reply }
    func decide(goal: String, plan: String, history: String, image: Data) async throws -> JevDecision {
        calls += 1
        return try reply()
    }
}
