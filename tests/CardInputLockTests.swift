import Foundation

@main
enum CardInputLockTests {
    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") }
        else  { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("CardInputLock.armedAt")
        check("lock window is 700 ms", CardInputLock.delay == 0.7)
        check("card shown on an empty screen → not locked",
              CardInputLock.armedAt(cardWasVisible: false, now: 100) == nil)
        check("card replaces a visible card → locked from now",
              CardInputLock.armedAt(cardWasVisible: true, now: 100) == 100)

        print("CardInputLock.isLocked")
        check("empty screen: never locked", !CardInputLock.isLocked(armedAt: nil, now: 100))
        let armed = CardInputLock.armedAt(cardWasVisible: true, now: 100)
        check("replaced card: locked at 0 ms", CardInputLock.isLocked(armedAt: armed, now: 100))
        check("replaced card: locked at 699 ms", CardInputLock.isLocked(armedAt: armed, now: 100.699))
        check("replaced card: free at 700 ms (lock expires)", !CardInputLock.isLocked(armedAt: armed, now: 100.7))
        check("replaced card: free long after", !CardInputLock.isLocked(armedAt: armed, now: 160))
        check("clock going backwards does not lock forever", !CardInputLock.isLocked(armedAt: armed, now: 99))

        print("CardInputLock.cardVisible")
        check("nothing on screen", !CardInputLock.cardVisible(approvalFD: -1, questionFD: -1, approvalShown: false, questionShown: false))
        check("real approval", CardInputLock.cardVisible(approvalFD: 7, questionFD: -1, approvalShown: true, questionShown: false))
        check("real question", CardInputLock.cardVisible(approvalFD: -1, questionFD: 9, approvalShown: false, questionShown: true))
        check("demo approval (no fd)", CardInputLock.cardVisible(approvalFD: -1, questionFD: -1, approvalShown: true, questionShown: false))
        check("demo question (no fd)", CardInputLock.cardVisible(approvalFD: -1, questionFD: -1, approvalShown: false, questionShown: true))

        print("CardInputLock.headChangeArmedAt")
        let a = UUID(), b = UUID()
        check("queue moves to another request while a card is shown → locked from now",
              CardInputLock.headChangeArmedAt(shownId: a, headId: b, now: 100) == 100)
        check("same request refreshed (count only) → not armed",
              CardInputLock.headChangeArmedAt(shownId: a, headId: a, now: 100) == nil)
        check("no card shown before → not armed (arrival arms itself)",
              CardInputLock.headChangeArmedAt(shownId: nil, headId: b, now: 100) == nil)
        check("head change locks clicks for the delay",
              CardInputLock.isLocked(armedAt: CardInputLock.headChangeArmedAt(shownId: a, headId: b, now: 100), now: 100.3))

        print("CardInputLock.handoverArmedAt (approval and question queues share one card)")
        let q1 = UUID(), q2 = UUID(), ap = UUID()
        check("question closes, an approval waiting behind it takes the card → locked from now",
              CardInputLock.handoverArmedAt(shown: q1, next: ap, now: 100) == 100)
        check("approval answered, a question takes the card → locked from now",
              CardInputLock.handoverArmedAt(shown: ap, next: q1, now: 100) == 100)
        check("first question answered, the second takes the card → locked from now",
              CardInputLock.handoverArmedAt(shown: q1, next: q2, now: 100) == 100)
        check("same card refreshed → not armed",
              CardInputLock.handoverArmedAt(shown: q1, next: q1, now: 100) == nil)
        check("nothing was shown → not armed (the arrival arms itself)",
              CardInputLock.handoverArmedAt(shown: nil, next: q1, now: 100) == nil)
        check("nothing takes the card → not armed",
              CardInputLock.handoverArmedAt(shown: q1, next: nil, now: 100) == nil)
        check("a second click 300 ms after question → approval handover is ignored",
              CardInputLock.isLocked(armedAt: CardInputLock.handoverArmedAt(shown: q1, next: ap, now: 100), now: 100.3))

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("Card input lock: all cases passed")
    }
}
