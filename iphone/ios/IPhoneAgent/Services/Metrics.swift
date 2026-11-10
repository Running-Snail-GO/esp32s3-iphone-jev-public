import Foundation

/// Live numbers for the Diagnostics page; a snapshot goes into every trace (metrics.json).
@MainActor final class Metrics: ObservableObject {
    struct Step: Codable {
        var frameMs = 0.0, llmMs = 0.0, hidMs = 0.0
        var checkMs = 0.0, totalMs = 0.0
        var actions = 0, planned = 0
        var interrupted = false
        var mode = "standard"
    }

    // board, from status
    @Published var board: BoardStatus?
    @Published var statusAge = 0.0  // s since the last status notify
    // BLE, measured in the app
    @Published var bleKbps = 0.0
    @Published var mtu = 0
    @Published var drops = 0
    @Published var benchKbps: Double?
    // video
    @Published var fps = 0.0
    @Published var idrIntervalMs: Double?
    @Published var snapMs: Double?
    @Published var decodeMs = 0.0
    @Published var decodeErrors = 0
    @Published var backgroundDecodeErrors = 0
    // agent
    @Published var steps: [Step] = []
    @Published var runRounds = 0
    @Published var runActions = 0
    @Published var modelRequests = 0
    @Published var modelWaitMs = 0.0
    @Published var runElapsedMs = 0.0
    private var runBegan: Double?

    func beginRun() {
        steps = []; runRounds = 0; runActions = 0; modelRequests = 0; modelWaitMs = 0
        runElapsedMs = 0; runBegan = now()
        llmFirstMs = nil; llmTotalMs = nil
        jevMs = nil; jevCalls = 0; jevFallbacks = 0
    }
    func endRun() {
        if let runBegan { runElapsedMs = (now() - runBegan) * 1000 }
        runBegan = nil
    }
    func modelRequest(seconds: Double) {
        modelRequests += 1
        modelWaitMs += max(0, seconds) * 1000
    }
    @Published var llmFirstMs: Double?
    @Published var llmTotalMs: Double?
    @Published var llmPingMs: Double?
    @Published var jevMs: Double?
    @Published var jevCalls = 0
    @Published var jevFallbacks = 0
    @Published var hidMs: [String: Double] = [:]  // last round trip per command
    // background
    @Published var backgroundSince: Double?
    @Published var backgroundAlive = 0.0  // s alive in background (current or last stint)
    @Published var suspensions = 0

    private var windowBytes = 0, windowFrames = 0
    private var windowStart = now()
    private var lastIDR: Double?
    private var lastTick = now()
    private var lastStatus: Double?

    func status(_ s: BoardStatus) {
        board = s
        lastStatus = now()
    }

    func videoBytes(_ n: Int) { windowBytes += n }
    func videoDrops(_ n: Int) { drops += n }
    func frameDecoded(ms: Double) {
        windowFrames += 1
        decodeMs = ms
    }
    func decodeError(background: Bool) {
        decodeErrors += 1
        if background { backgroundDecodeErrors += 1 }
    }
    func idrSeen() {
        let t = now()
        if let lastIDR { idrIntervalMs = (t - lastIDR) * 1000 }
        lastIDR = t
    }
    func snapLatency(_ ms: Double) { snapMs = ms }
    func llm(first: Double?, total: Double) {
        llmFirstMs = first.map { $0 * 1000 }
        llmTotalMs = total * 1000
    }
    func jev(ms: Double, fallback: Bool) {
        modelRequest(seconds: ms / 1000)
        jevMs = ms
        jevCalls += 1
        if fallback { jevFallbacks += 1 }
    }
    func step(_ s: Step) {
        runRounds += 1
        runActions += s.actions
        steps = Array((steps + [s]).suffix(40))
        DebugLog.write(String(format: "round %d timing: total %.0f ms, frame %.0f ms, LLM %.0f ms, HID %.0f ms, check %.0f ms, actions %d/%d (%@)", runRounds, s.totalMs, s.frameMs,
                              s.llmMs, s.hidMs, s.checkMs, s.actions, s.planned, s.mode))
    }

    /// Called every second by a timer; also detects suspension (a gap far longer than the tick).
    func tick() {
        let t = now()
        if let runBegan { runElapsedMs = (t - runBegan) * 1000 }
        if t - lastTick > 5 { suspensions += 1 }
        lastTick = t
        let span = max(t - windowStart, 0.001)
        bleKbps = Double(windowBytes) * 8 / 1000 / span
        fps = Double(windowFrames) / span
        windowBytes = 0; windowFrames = 0; windowStart = t
        statusAge = lastStatus.map { t - $0 } ?? 0
        if let since = backgroundSince { backgroundAlive = t - since }
    }

    func enteredBackground() { backgroundSince = now(); backgroundAlive = 0 }
    func enteredForeground() { backgroundSince = nil }

    /// Everything as JSON-ready values, for metrics.json.
    func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "ble_kbps_app": bleKbps, "mtu": mtu, "drops": drops, "fps": fps, "decode_ms": decodeMs,
            "decode_errors": decodeErrors, "background_decode_errors": backgroundDecodeErrors,
            "background_alive_s": backgroundAlive, "suspensions": suspensions, "hid_ms": hidMs,
            "steps": steps.map { ["frame_ms": $0.frameMs, "llm_ms": $0.llmMs, "hid_ms": $0.hidMs,
                                   "check_ms": $0.checkMs, "total_ms": $0.totalMs, "actions": $0.actions,
                                   "planned": $0.planned, "interrupted": $0.interrupted, "mode": $0.mode] as [String: Any] },
            "run_rounds": runRounds, "run_actions": runActions, "model_requests": modelRequests,
            "model_wait_ms": modelWaitMs, "run_elapsed_ms": runElapsedMs,
        ]
        out["bench_kbps"] = benchKbps
        out["idr_interval_ms"] = idrIntervalMs
        out["snap_ms"] = snapMs
        out["llm_first_ms"] = llmFirstMs
        out["llm_total_ms"] = llmTotalMs
        out["jev_ms"] = jevMs
        out["jev_calls"] = jevCalls
        out["jev_fallbacks"] = jevFallbacks
        if let board, let data = try? JSONEncoder().encode(board) {
            out["board"] = try? JSONSerialization.jsonObject(with: data)
        }
        return out
    }
}
