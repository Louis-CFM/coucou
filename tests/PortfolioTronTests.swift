import Foundation

// Standalone test for TronAccount.parse (compiled with TronAccount.swift by scripts/test-portfolio-tron.sh).
func json(_ s: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
}
func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

@main
struct PortfolioTronTests {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) \(detail())") }
        }
        // Caio's real answer: ~291 TRX, 320057.803779 USDT, one unknown (spam) token.
        let real = json("""
        {"data":[{"balance":291265503,"trc20":[{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"320057803779"},{"TGPuQ7g7H8GsUEXhwvvJop4zCncurEh2ht":"88123456"}]}],"success":true}
        """)
        let h = TronAccount.parse(real)
        check("real: TRX first then USDT, unknown skipped", h.map(\.symbol) == ["TRX", "USDT"], "\(h)")
        check("real: TRX amount", h.first.map { close($0.amount, 291.265503) } ?? false, "\(h)")
        check("real: USDT amount", h.count > 1 && close(h[1].amount, 320057.803779), "\(h)")

        let empty = TronAccount.parse(json(#"{"data":[],"success":true}"#))
        // Contract: parse always returns TRX first, so an empty account is exactly [TRX 0].
        check("empty account -> exactly TRX 0", empty == [TronHolding(symbol: "TRX", amount: 0)], "\(empty)")

        let noBalance = TronAccount.parse(json(#"{"data":[{"trc20":[{"TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8":"2500000"}]}]}"#))
        check("no balance key: TRX 0, USDC 2.5", noBalance.map(\.symbol) == ["TRX", "USDC"]
              && noBalance[0].amount == 0 && close(noBalance[1].amount, 2.5), "\(noBalance)")

        // 9_000_000_000_000_000 raw units = 9e9 USDT, far above Int32.
        let big = TronAccount.parse(json(#"{"data":[{"balance":1,"trc20":[{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"9000000000000000"}]}]}"#))
        check("amount above Int32", big.count == 2 && close(big[1].amount, 9_000_000_000), "\(big)")

        let garbage = TronAccount.parse(json(#"{"data":[{"balance":5000000,"trc20":[{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"abc"}]}]}"#))
        check("non-numeric token amount skipped", garbage.map(\.symbol) == ["TRX"], "\(garbage)")

        let strict = TronAccount.parse(json(#"{"data":[{"balance":0,"trc20":[{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"12abc"},{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"-5"},{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"1e3"},{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":""}]}]}"#))
        check("partially numeric, negative, exponent and empty amounts skipped", strict.map(\.symbol) == ["TRX"], "\(strict)")

        // 5_000_000_000_000 sun = 5_000_000 TRX, above Int32 (a regression to Int32 would fail here).
        let bigTRX = TronAccount.parse(json(#"{"data":[{"balance":5000000000000}]}"#))
        check("TRX balance above Int32", bigTRX.count == 1 && close(bigTRX[0].amount, 5_000_000), "\(bigTRX)")

        // The same contract twice, and USDC after USDT: one row per symbol, summed, first-seen order.
        let dup = TronAccount.parse(json(#"{"data":[{"balance":1000000,"trc20":[{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"1500000"},{"TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8":"2000000"},{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"2500000"}]}]}"#))
        check("repeated contract summed, unique symbols in first-seen order",
              dup.map(\.symbol) == ["TRX", "USDT", "USDC"] && close(dup[1].amount, 4.0) && close(dup[2].amount, 2.0), "\(dup)")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
