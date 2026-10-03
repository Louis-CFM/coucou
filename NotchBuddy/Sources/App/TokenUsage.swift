import Foundation

struct TokenUsage: Equatable {
    let prompt: Int
    let completion: Int

    var total: Int { prompt + completion }

    static func parse(_ json: [String: Any]) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any] else { return nil }
        let prompt = usage["prompt_tokens"] as? Int ?? usage["input_tokens"] as? Int
        let completion = usage["completion_tokens"] as? Int ?? usage["output_tokens"] as? Int
        if let prompt, let completion, prompt + completion > 0 {
            return TokenUsage(prompt: prompt, completion: completion)
        }
        if let total = usage["total_tokens"] as? Int, total > 0 {
            return TokenUsage(prompt: total, completion: 0)
        }
        return nil
    }

    static func dayKey(_ date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
