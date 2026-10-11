import Foundation
import SwiftUI

// MARK: - StripePoller
// Polls Stripe API every 30s for balance + recent charges.
// On new charge: slides payments list (newest first), then animates balance count-up.

final class StripePoller: @unchecked Sendable {
    static let shared = StripePoller()
    private var timer: DispatchSourceTimer?
    private var lastChargeId: String = ""

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 6, repeating: 30)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    // MARK: - Poll

    func pollNow() { poll() }

    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        guard let key = KeychainStore.shared.get("stripe-api-key") else { return }
        fetchBalance(key: key)
        fetchCharges(key: key)
    }

    // MARK: - Balance

    private func fetchBalance(key: String) {
        guard let url = URL(string: "https://api.stripe.com/v1/balance") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        // Stripe primary auth: Basic with key as username, empty password
        let creds = Data("\(key):".utf8).base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: req) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                let errMsg: String
                if code == 401 { errMsg = "Invalid API key (401)" }
                else if code == 403 { errMsg = "Use secret key (sk_live_… not pk_live_…)" }
                else if code == 0   { errMsg = error?.localizedDescription ?? "No connection" }
                else                { errMsg = "API error \(code)" }
                DispatchQueue.main.async { AppState.shared.stripeError = errMsg }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            // Sum available + pending so recent charges show up immediately
            let available = json["available"] as? [[String: Any]] ?? []
            let pending   = json["pending"]   as? [[String: Any]] ?? []
            let allBuckets = available + pending
            guard let currency = (allBuckets.first)?["currency"] as? String else { return }
            let amount = allBuckets.compactMap { $0["amount"] as? Int }.reduce(0, +)

            DispatchQueue.main.async {
                let state = AppState.shared
                state.stripeError    = nil
                state.stripeCurrency = currency
                state.stripeBalance  = amount
                // Always sync display balance if not yet showing a real value
                // (charges may have set stripeLoaded=true before balance arrived)
                if state.stripeDisplayBalance == 0 {
                    state.stripeDisplayBalance = amount
                }
                state.stripeLoaded = true
            }
        }.resume()
    }

    // MARK: - Charges

    private func fetchCharges(key: String) {
        guard let url = URL(string: "https://api.stripe.com/v1/charges?limit=3") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        let creds = Data("\(key):".utf8).base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawList = json["data"] as? [[String: Any]] else { return }

            let parsed = rawList.compactMap { self.parseCharge($0) }
            DispatchQueue.main.async { self.handleCharges(parsed) }
        }.resume()
    }

    private func parseCharge(_ c: [String: Any]) -> StripePayment? {
        guard let id       = c["id"]       as? String,
              let amount   = c["amount"]   as? Int,
              let currency = c["currency"] as? String,
              let status   = c["status"]   as? String else { return nil }

        let ts   = (c["created"] as? TimeInterval) ?? 0
        let desc = c["description"] as? String
            ?? (c["billing_details"] as? [String: Any]).flatMap { $0["name"] as? String }

        return StripePayment(id: id, amount: amount, currency: currency,
                             description: desc, createdAt: Date(timeIntervalSince1970: ts),
                             status: status)
    }

    @MainActor
    private func handleCharges(_ payments: [StripePayment]) {
        let state = AppState.shared

        // First load — populate silently, anchor lastChargeId to avoid duplicate on next poll
        if state.stripePayments.isEmpty {
            state.stripePayments = payments
            lastChargeId = payments.first?.id ?? ""
            // Sync display balance (balance may have already arrived; use it)
            state.stripeDisplayBalance = state.stripeBalance
            state.stripeLoaded = true
            return
        }

        guard let newest = payments.first, newest.id != lastChargeId else { return }
        lastChargeId = newest.id

        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_stripe" }) else { return }
        let focused = state.focusId == "integration_stripe"

        // 1. Slide payments: new enters top, max 3 shown
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            state.stripePayments = Array(([newest] + state.stripePayments).prefix(3))
        }

        state.tasks[idx].state = .finished
        state.tasks[idx].steps = [newest.description ?? newest.amountFormatted]
        if !focused { state.tasks[idx].pillBadge = .finished }
        SoundEngine.shared.play("finish")

        // 2. After slide settles, count up balance
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 1.2)) {
                state.stripeDisplayBalance = state.stripeBalance
            }
        }

        // 3. Auto-clear task state after 60s
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = state.tasks.firstIndex(where: { $0.id == "integration_stripe" }) else { return }
            guard state.tasks[i].state == .finished else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
            state.tasks[i].pillBadge = nil
        }
    }
}

