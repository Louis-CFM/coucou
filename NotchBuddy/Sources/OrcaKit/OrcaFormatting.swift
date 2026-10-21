import Foundation

public enum OrcaLanguage: String, Sendable { case en, pt }

/// Display text rules from docs/api.md (`ago`, `resetText`) plus state labels.
public enum OrcaFormatting {
    /// `now`/`agora`, `N min`, `N h`, `N d`.
    public static func ago(since epoch: Int, now: Date = Date(), lang: OrcaLanguage = .en) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970) - epoch)
        switch seconds {
        case ..<60: return lang == .pt ? "agora" : "now"
        case ..<3600: return "\(seconds / 60) min"
        case ..<86400: return "\(seconds / 3600) h"
        default: return "\(seconds / 86400) d"
        }
    }

    private static let weekdays: [OrcaLanguage: [String]] = [
        .en: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"],
        .pt: ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"],
    ]

    /// `HH:MM` if the reset is today, weekday abbreviation within the next 6 days,
    /// else `dd/mm` (pt) or `mm/dd` (en).
    public static func resetText(resetsAt epoch: Int, now: Date = Date(), calendar: Calendar = .current,
                                 lang: OrcaLanguage = .en) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        let c = calendar.dateComponents([.hour, .minute, .day, .month, .weekday], from: date)
        if days == 0 { return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }
        if days > 0, days <= 6, let wd = c.weekday { return weekdays[lang]![(wd - 1) % 7] }
        let (d, m) = (c.day ?? 0, c.month ?? 0)
        return lang == .pt ? String(format: "%02d/%02d", d, m) : String(format: "%02d/%02d", m, d)
    }

    public static func stateLabel(_ state: OrcaWorkspaceState, lang: OrcaLanguage = .en) -> String {
        switch (state, lang) {
        case (.failed, .en): "Failed"
        case (.attention, .en): "Needs you"
        case (.running, .en): "Running"
        case (.review, .en): "In review"
        case (.done, .en): "Done"
        case (.idle, .en): "Idle"
        case (.failed, .pt): "Falhou"
        case (.attention, .pt): "Precisa de você"
        case (.running, .pt): "Rodando"
        case (.review, .pt): "Em revisão"
        case (.done, .pt): "Concluído"
        case (.idle, .pt): "Parado"
        }
    }

    public static func prText(_ pr: OrcaPullRequest?) -> String? {
        guard let pr, let number = pr.number else { return nil }
        guard let state = pr.state else { return "PR #\(number)" }
        return "PR #\(number) · \(state)"
    }

    /// Percentage clamped to 0...100, as a 0...1 fraction for bars.
    public static func clampedFraction(_ pct: Double?) -> Double {
        guard let pct, pct.isFinite else { return 0 }
        return min(max(pct, 0), 100) / 100
    }

    /// One line, trimmed, at most `limit` characters (ellipsis when cut).
    static func oneLine(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if flat.isEmpty { return nil }
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    static func providerLabel(_ provider: String) -> String {
        switch provider {
        case "claude": "Claude"
        case "codex": "Codex"
        case "gemini": "Gemini"
        case "opencode-go": "OpenCode Go"
        case "kimi": "Kimi"
        case "antigravity": "Antigravity"
        case "minimax": "MiniMax"
        default: provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }
}
