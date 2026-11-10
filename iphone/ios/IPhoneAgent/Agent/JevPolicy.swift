import Foundation

/// Turn typed Jev evidence into a bounded navigation action. A Box is not proof
/// that a target exists, so taps require independent presence evidence as well.
enum JevPolicy {
    static func action(for decision: JevDecision, minConfidence: Double) -> JObject? {
        guard minConfidence.isFinite, (0.5...0.99).contains(minConfidence),
              probability(decision.confidence), probability(decision.safeToAct),
              probability(decision.targetPresent), probability(decision.goalComplete),
              decision.confidence >= minConfidence, decision.safeToAct >= minConfidence,
              decision.goalComplete < minConfidence else { return nil }
        switch decision.action {
        case .tap:
            guard decision.targetPresent >= max(0.9, minConfidence), let box = decision.box, box.isValid,
                  box.confidence.map({ $0 >= minConfidence }) != false,
                  (box.right - box.left) * (box.bottom - box.top) <= 0.25 else { return nil }
            return ["action": .str("tap"), "x": .int(Int((box.centerX * 1000).rounded())),
                    "y": .int(Int((box.centerY * 1000).rounded()))]
        case .scrollUp:
            return ["action": .str("swipe"), "x1": .int(500), "y1": .int(350), "x2": .int(500), "y2": .int(600)]
        case .scrollDown:
            return ["action": .str("swipe"), "x1": .int(500), "y1": .int(650), "x2": .int(500), "y2": .int(400)]
        case .home: return ["action": .str("home")]
        case .back: return ["action": .str("back")]
        case .wait: return ["action": .str("wait")]
        case .done, .vision:
            // The vision actor checks completion and produces the user-facing
            // answer. Text generation and confirmation retain their existing path.
            return nil
        }
    }

    private static func probability(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }
}
