import Foundation

@main
enum KoreanSpeechLevelTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("\nKorean speech level")
        check("as spoken adds no instruction", KoreanSpeechLevel.keep.rule == nil)
        let rules = KoreanSpeechLevel.allCases.compactMap { $0.rule }
        check("every other level adds one", rules.count == KoreanSpeechLevel.allCases.count - 1)
        check("the instructions differ", Set(rules).count == rules.count)
        check("polite names 해요체", KoreanSpeechLevel.haeyo.rule?.contains("해요체") == true)
        check("formal names 합니다체", KoreanSpeechLevel.hamnida.rule?.contains("합니다체") == true)
        check("casual names 해체", KoreanSpeechLevel.banmal.rule?.contains("해체") == true)
        check("other languages are left alone", rules.allSatisfy { $0.contains("other languages") })
        check("each level gives an example", rules.allSatisfy { $0.contains("Example:") && $0.contains("→") })
        check("the pronoun is handled, not only the ending", rules.allSatisfy { $0.contains("너") })
        check("stored as a stable raw value", KoreanSpeechLevel(rawValue: "haeyo") == .haeyo
              && KoreanSpeechLevel(rawValue: "") == nil)
        print(failures == 0 ? "\nAll good.\n" : "\n\(failures) failed.\n")
        exit(failures == 0 ? 0 : 1)
    }
}
