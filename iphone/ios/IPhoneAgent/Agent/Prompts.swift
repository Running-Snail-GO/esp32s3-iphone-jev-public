import Foundation

/// The model prompts, kept as plain text in the repository's `prompts/` folder (bundled with the app) so they
/// can be read and tuned without touching Swift. actor/planner = the shared rules + the app-only rules.
enum Prompts {
    static let planner = load("planner")
    static let actorServer = load("actor")
    static let appRules = load("app-rules")
    /// Copies items off one screen for the notebook (the `read` action).
    static let reader = load("reader")

    static let actor = actorServer + "\n" + appRules + language
    static let plannerApp = planner + "\n" + appRules + language

    static let predictive = """
    PREDICTIVE EXECUTION MODE (overrides the ordinary same-screen batching rule):
    Return up to 3 DO lines to reduce model round trips. The first action can use the normal syntax.
    Every following action MUST be: tap_text EXACT VISIBLE LABEL
    tap_text finds one exact, unique text label on a fresh screenshot on the phone, and taps its center.
    You may predict conventional next-page navigation labels, using the phone's actual UI language.
    If the label is absent, duplicated, or the screen is unavailable, the batch stops and you see a new screenshot.
    Never guess later-page coordinates. Icon-only targets need a new look and a normal coordinate tap.
    Do not predict toggle/checkmark state on a page you have not seen. Do not batch sending, paying,
    deleting, or account/security changes; follow the confirmation rule and re-observe before such actions.
    Text entry, keyboard switching, completion and confirmation end a batch. Say done only after seeing success.
    Keep THINK to one short sentence; do not restate the plan.
    Example (only if these are the phone's actual navigation labels):
    DO: tap 500 600
    DO: tap_text 闹钟
    DO: tap_text 编辑
    """

    /// The plan and notes show up in the app: write them in the app's language. Actions and JSON keys stay as specified.
    static let language = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        ? "\nWrite the plan, notes and reasons in Simplified Chinese. Action names, JSON keys and coordinates stay as specified."
        : ""

    /// One file from the bundled prompts folder, without the file's final newline.
    static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "prompts"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("prompts/\(name).md is missing from the app bundle")
        }
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}
