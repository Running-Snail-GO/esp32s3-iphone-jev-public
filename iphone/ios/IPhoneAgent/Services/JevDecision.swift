import Foundation

/// Jev chooses from this fixed navigation vocabulary. Text input, app-name
/// generation, complex gestures and confirmation requests return to the VLM.
enum JevAction: String, Codable, CaseIterable, Sendable {
    case tap
    case scrollUp = "scroll_up"
    case scrollDown = "scroll_down"
    case back, home, wait, done, vision
}

/// Normalized image edges, measured from the top-left corner.
struct JevBox: Equatable, Sendable {
    let left: Double
    let top: Double
    let right: Double
    let bottom: Double
    let confidence: Double?

    var centerX: Double { (left + right) / 2 }
    var centerY: Double { (top + bottom) / 2 }

    var isValid: Bool {
        [left, top, right, bottom].allSatisfy(Self.isProbability)
            && left < right && top < bottom
            && (right - left) * (bottom - top) > 0
            && confidence.map(Self.isProbability) != false
    }

    fileprivate static func isProbability(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }
}

/// This is evidence, not an executable command. The caller must apply its
/// confidence/presence policy and check that this screenshot is still current.
struct JevDecision: Equatable, Sendable {
    let action: JevAction
    let confidence: Double
    let targetPresent: Double
    let safeToAct: Double
    let goalComplete: Double
    let box: JevBox?
    let seconds: Double
    let servedModel: String?
    let usage: [String: Int]

    init(action: JevAction, confidence: Double, targetPresent: Double,
         safeToAct: Double, goalComplete: Double, box: JevBox? = nil,
         seconds: Double, servedModel: String? = nil, usage: [String: Int] = [:]) {
        self.action = action
        self.confidence = confidence
        self.targetPresent = targetPresent
        self.safeToAct = safeToAct
        self.goalComplete = goalComplete
        self.box = box
        self.seconds = seconds
        self.servedModel = servedModel
        self.usage = usage
    }

    /// Reject malformed or partial answers instead of defaulting to a tap.
    /// A Box is never evidence that the target exists: Jev returns one even
    /// when absent. The independent visible answer must be checked by the caller.
    static func decode(_ data: Data, seconds: Double) throws -> JevDecision {
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            let answers = response.answers
            guard !response.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seconds.isFinite, seconds >= 0,
                  answers.action.type == "choice",
                  answers.visible.type == "noul", answers.safe.type == "noul",
                  answers.complete.type == "noul",
                  [answers.action.confidence, answers.visible.noul,
                   answers.safe.noul, answers.complete.noul].allSatisfy(JevBox.isProbability),
                  validChoice(answers.action),
                  response.usage.inputTokens >= 0, response.usage.outputTokens >= 0
            else { throw JevClientError.invalidResponse }

            let box = answers.target.map {
                JevBox(left: $0.box.left, top: $0.box.top, right: $0.box.right,
                       bottom: $0.box.bottom, confidence: $0.confidence)
            }
            if let target = answers.target {
                guard target.type == "box", box?.isValid == true else { throw JevClientError.invalidResponse }
            }
            if answers.action.choice == .tap, box == nil { throw JevClientError.invalidResponse }
            return JevDecision(action: answers.action.choice, confidence: answers.action.confidence,
                               targetPresent: answers.visible.noul, safeToAct: answers.safe.noul,
                               goalComplete: answers.complete.noul, box: box, seconds: seconds,
                               servedModel: response.model,
                               usage: ["prompt_tokens": response.usage.inputTokens,
                                       "completion_tokens": response.usage.outputTokens])
        } catch {
            // Decoder errors may contain server-controlled text. Never relay it
            // to logs or UI where it could contain task data or credentials.
            throw JevClientError.invalidResponse
        }
    }

    private static func validChoice(_ answer: Choice) -> Bool {
        let probabilities = answer.probabilities
        guard Set(probabilities.keys) == Set(JevAction.allCases.map(\.rawValue)),
              probabilities.values.allSatisfy(JevBox.isProbability),
              let selected = probabilities[answer.choice.rawValue],
              let maximum = probabilities.values.max(),
              selected + 0.000_001 >= maximum,
              abs(probabilities.values.reduce(0, +) - 1) <= 0.01 else { return false }
        // Choice confidence summarizes the distribution; it is not the selected
        // option's probability. Check the documented formula, with tolerance for
        // rounded server values, rather than accepting contradictory evidence.
        // https://docs.typesafe.ai/confidence#choice
        let uniform = 1 / Double(probabilities.count)
        let expected = (maximum - uniform) / (1 - uniform)
        return abs(answer.confidence - expected) <= 0.02
    }

    private struct Response: Decodable {
        let model: String
        let answers: Answers
        let usage: Usage
    }
    private struct Answers: Decodable {
        let action: Choice
        let visible: Noul
        let safe: Noul
        let complete: Noul
        let target: Box?
    }
    private struct Choice: Decodable {
        let type: String
        let choice: JevAction
        let confidence: Double
        let probabilities: [String: Double]
    }
    private struct Noul: Decodable {
        let type: String
        let noul: Double
    }
    private struct Box: Decodable {
        let type: String
        let box: Edges
        let confidence: Double?
    }
    private struct Edges: Decodable {
        let left: Double
        let top: Double
        let right: Double
        let bottom: Double
    }
    private struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}

/// Only controlled descriptions escape this boundary, never raw HTTP bodies.
enum JevClientError: LocalizedError, Equatable {
    case missingKey
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey: return String(localized: "Add your TypeSafe API key before using Jev.")
        case .invalidRequest: return String(localized: "Jev needs a task, model, API key and a JPEG screenshot within its size limits.")
        case .invalidResponse: return String(localized: "Jev returned an invalid decision. Using the vision model instead.")
        case .httpStatus(let code): return String(localized: "Jev request failed (HTTP \(code)). Using the vision model instead.")
        }
    }
}
