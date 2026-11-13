import Foundation

/// When to ask for an App Store review: after enough good moments (sessions finished on the Mac,
/// decisions sent from the iPhone), never in the first days, at most once per version. Apple itself
/// shows the request at most three times a year, and never to someone who turned it off.
enum ReviewPolicy {
    /// Good moments before the first ask.
    static let macMoments = 8
    static let phoneMoments = 5
    /// Days after the first good moment.
    static let minDays: Double = 3

    static func shouldAsk(moments: Int, needed: Int, firstSeen: Date, now: Date,
                          askedVersion: String?, version: String) -> Bool {
        moments >= needed && now.timeIntervalSince(firstSeen) >= minDays * 86_400 && askedVersion != version
    }

    private static let countKey = "appReview.moments"
    private static let firstKey = "appReview.firstSeen"
    private static let askedKey = "appReview.askedVersion"

    /// One more good moment. True when now is the time to ask; this version is then remembered
    /// as asked, and the count starts again.
    static func note(needed: Int, defaults: UserDefaults = .standard, now: Date = Date(),
                     version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") -> Bool {
        // Already asked for this version: the moments count toward the next one only.
        guard defaults.string(forKey: askedKey) != version else { return false }
        if defaults.object(forKey: firstKey) == nil { defaults.set(now, forKey: firstKey) }
        let moments = defaults.integer(forKey: countKey) + 1
        defaults.set(moments, forKey: countKey)
        let first = defaults.object(forKey: firstKey) as? Date ?? now
        guard shouldAsk(moments: moments, needed: needed, firstSeen: first, now: now,
                        askedVersion: defaults.string(forKey: askedKey), version: version) else { return false }
        defaults.set(version, forKey: askedKey)
        defaults.set(0, forKey: countKey)
        return true
    }
}
