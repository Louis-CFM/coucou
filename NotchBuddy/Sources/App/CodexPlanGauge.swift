#if !APPSTORE
import SwiftUI

// MARK: - Codex plan usage

struct CodexPlanUsage {
    var fiveHour: PlanWindow?
    var sevenDay: PlanWindow?
    var resetCredits: Int?         // free full resets available
    var resetCreditExpiresAt: Date? // soonest expiry among them
    var planType: String?
    var updatedAt: Date

    var planUsage: PlanUsage { PlanUsage(fiveHour: fiveHour, sevenDay: sevenDay, updatedAt: updatedAt) }
}

// MARK: - Fetching (codex app-server, the source behind Codex's /status)

enum CodexPlanGauge {

    static func codexExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/Library/pnpm/codex",
        ]
        // nvm: one bin folder per Node version, newest first.
        let nvmNode = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmNode) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += sorted.map { "\(nvmNode)/\($0)/bin/codex" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `codex app-server` and asks for `account/rateLimits/read`. nil if Codex is missing or not signed in.
    static func fetch() async -> CodexPlanUsage? {
        guard let codex = codexExecutable() else { return nil }
        return await Task.detached { readRateLimits(codex: codex) }.value
    }

    private static func readRateLimits(codex: String) -> CodexPlanUsage? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [URL(fileURLWithPath: codex).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { if process.isRunning { process.terminate() } }

        // Give up after 15 s: terminating closes stdout, which ends the read loop.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"coucou","version":"1"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))

        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["id"] as? Int == 2 else { continue }
                return (obj["result"] as? [String: Any]).flatMap(parse)
            }
        }
    }

    /// Parses an `account/rateLimits/read` result.
    static func parse(result: [String: Any]) -> CodexPlanUsage? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        var usage = CodexPlanUsage(planType: limits["planType"] as? String, updatedAt: Date())
        // primary/secondary are not fixed to a window: sort them by duration
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any],
                  let pct = w["usedPercent"] as? Double,
                  let resetsAt = w["resetsAt"] as? Double else { continue }
            let window = PlanWindow(usedPct: min(100, max(0, pct)), resetsAt: Date(timeIntervalSince1970: resetsAt))
            if let mins = w["windowDurationMins"] as? Int, mins <= 24 * 60 {
                usage.fiveHour = window
            } else {
                usage.sevenDay = window
            }
        }
        if let resets = result["rateLimitResetCredits"] as? [String: Any] {
            usage.resetCredits = resets["availableCount"] as? Int
            let expiries = (resets["credits"] as? [[String: Any]] ?? [])
                .filter { $0["status"] as? String == "available" }
                .compactMap { $0["expiresAt"] as? Double }
            usage.resetCreditExpiresAt = expiries.min().map { Date(timeIntervalSince1970: $0) }
        }
        guard usage.fiveHour != nil || usage.sevenDay != nil else { return nil }
        return usage
    }

    static func pillLabel(_ usage: CodexPlanUsage?) -> String {
        guard let usage, let pct = ClaudePlanGauge.dominantPct(usage.planUsage) else { return "Codex —" }
        return "Codex \(Int(pct.rounded()))%"
    }

    static func color(_ usage: CodexPlanUsage?) -> String {
        ClaudePlanGauge.color(for: usage.flatMap { ClaudePlanGauge.dominantPct($0.planUsage) })
    }
}

// MARK: - Codex Plan Card View

private let resetExpiryFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "MMM d"
    return fmt
}()

struct CodexPlanCardView: View {
    let usage: CodexPlanUsage?   // nil = loading or unavailable

    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: CodexPlanGauge.color(usage)))
                    .frame(width: 7, height: 7)
                Text("Codex plan")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            // Gauge rows
            VStack(alignment: .leading, spacing: 5) {
                if usage?.fiveHour != nil {
                    GaugeRowView(label: "5 hours", window: usage?.fiveHour, now: now)
                }
                GaugeRowView(label: "Week", window: usage?.sevenDay, now: now, weekly: true)
                HStack(spacing: 5) {
                    Text("Resets")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .frame(width: 40, alignment: .leading)
                    Text(resetsText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.top, 8)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        // Update countdown every 30s, only while visible
        .background(
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Color.clear.onChange(of: ctx.date) { _, d in now = d }
            }
        )
    }

    private var subtitleText: String {
        guard let usage else { return "Asking Codex…" }
        let plan = usage.planType.map { "\($0) · " } ?? ""
        let diff = now.timeIntervalSince(usage.updatedAt)
        if diff < 60 { return plan + "just now" }
        let mins = Int(diff / 60)
        if mins < 60 { return plan + "\(mins) min ago" }
        return plan + "\(mins / 60) h ago"
    }

    private var resetsText: String {
        guard let count = usage?.resetCredits else { return "—" }
        var text = "\(count) available"
        if count > 0, let exp = usage?.resetCreditExpiresAt {
            text += " · until \(resetExpiryFormatter.string(from: exp))"
        }
        return text
    }
}
#endif
