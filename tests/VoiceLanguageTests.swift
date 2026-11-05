import Foundation

@main
struct VoiceLanguageTests {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  ok  \(name)" : "  FAIL \(name)")
            if !ok { failures += 1 }
        }

        print("VoiceLang(code:)")
        check("en", VoiceLang(code: "en") == .en)
        check("fr", VoiceLang(code: "fr") == .fr)
        check("pt", VoiceLang(code: "pt") == .pt)
        check("pt-BR", VoiceLang(code: "pt-BR") == .pt)
        check("pt_BR", VoiceLang(code: "pt_BR") == .pt)
        check("pt-PT", VoiceLang(code: "pt-PT") == .pt)
        check("fr-FR", VoiceLang(code: "fr-FR") == .fr)
        check("en-US", VoiceLang(code: "en-US") == .en)
        check("uppercase PT", VoiceLang(code: "PT") == .pt)
        check("unknown is en", VoiceLang(code: "de") == .en)
        check("empty is en", VoiceLang(code: "") == .en)
        check("auto is en", VoiceLang(code: "auto") == .en)

        print("VoiceLang(locale:)")
        check("pt_BR locale", VoiceLang(locale: Locale(identifier: "pt_BR")) == .pt)
        check("pt-BR locale", VoiceLang(locale: Locale(identifier: "pt-BR")) == .pt)
        check("fr_FR locale", VoiceLang(locale: Locale(identifier: "fr_FR")) == .fr)
        check("nil locale is en", VoiceLang(locale: nil) == .en)

        print("VoiceLang locales and names")
        check("en locale", VoiceLang.en.locale.identifier == "en-US" || VoiceLang.en.locale.identifier == "en_US")
        check("pt locale is Portuguese/Brazil", VoiceLang.pt.locale.language.languageCode?.identifier == "pt"
              && VoiceLang.pt.locale.region?.identifier == "BR")
        check("fr locale is French/France", VoiceLang.fr.locale.language.languageCode?.identifier == "fr"
              && VoiceLang.fr.locale.region?.identifier == "FR")
        check("pt format locale", VoiceLang.pt.formatLocale.identifier == "pt_BR")
        check("fr format locale", VoiceLang.fr.formatLocale.identifier == "fr_FR")
        check("en format locale", VoiceLang.en.formatLocale.identifier == "en_US")
        check("pt money uses a comma", VoiceLang.pt.formatLocale.decimalSeparator == ",")
        check("english name", VoiceLang.en.englishName == "English")
        check("french name", VoiceLang.fr.englishName == "French")
        check("pt name", VoiceLang.pt.englishName == "Brazilian Portuguese")
        for l in VoiceLang.allCases { check("round trip \(l.rawValue)", VoiceLang(locale: l.locale) == l) }

        print("VoiceLang.defaultCode")
        check("pt-BR Mac", VoiceLang.defaultCode(appPortuguese: false, preferred: ["pt-BR"], region: "BR") == "pt")
        check("pt-PT Mac", VoiceLang.defaultCode(appPortuguese: false, preferred: ["pt-PT", "en"], region: "PT") == "pt")
        check("app Portuguese wins over fr", VoiceLang.defaultCode(appPortuguese: true, preferred: ["fr-FR"], region: "FR") == "pt")
        check("app Portuguese wins over en-US", VoiceLang.defaultCode(appPortuguese: true, preferred: ["en-US"], region: "US") == "pt")
        check("en-BR stays en", VoiceLang.defaultCode(appPortuguese: false, preferred: ["en-BR"], region: "BR") == "en")
        check("region BR alone is pt", VoiceLang.defaultCode(appPortuguese: false, preferred: [], region: "br") == "pt")
        check("region BR with non en/fr first is pt", VoiceLang.defaultCode(appPortuguese: false, preferred: ["es-ES"], region: "BR") == "pt")
        check("English Mac in Brazil stays en", VoiceLang.defaultCode(appPortuguese: false, preferred: ["en-US"], region: "BR") == "en")
        check("French Mac in Brazil stays en", VoiceLang.defaultCode(appPortuguese: false, preferred: ["fr-FR"], region: "BR") == "en")
        check("en-US is en", VoiceLang.defaultCode(appPortuguese: false, preferred: ["en-US"], region: "US") == "en")
        check("fr-FR is en", VoiceLang.defaultCode(appPortuguese: false, preferred: ["fr-FR"], region: "FR") == "en")
        check("no info is en", VoiceLang.defaultCode(appPortuguese: false, preferred: [], region: nil) == "en")
        check("pt only second is en", VoiceLang.defaultCode(appPortuguese: false, preferred: ["fr", "pt-BR"], region: "FR") == "en")

        print("VoiceLang.detect")
        check("pt image ready", VoiceLang.detect("a imagem está pronta") == .pt)
        check("pt thanks", VoiceLang.detect("obrigado, você pode mandar amanhã") == .pt)
        check("pt tell him", VoiceLang.detect("dizendo que o arquivo está no Drive") == .pt)
        check("fr image ready", VoiceLang.detect("l'image est prête") == .fr)
        check("fr thanks", VoiceLang.detect("merci pour le fichier") == .fr)
        check("en image ready", VoiceLang.detect("the image is ready") == .en)
        check("en thanks", VoiceLang.detect("thanks for the file, see you tomorrow") == .en)
        check("empty is en", VoiceLang.detect("") == .en)
        check("unknown words are en", VoiceLang.detect("GitHub Stripe Vercel") == .en)
        check("fr and en tie is en", VoiceLang.detect("the le") == .en)
        check("en tell him no", VoiceLang.detect("tell him no") == .en)
        check("en as soon as possible", VoiceLang.detect("let her know as soon as possible") == .en)
        check("en tell her no problem", VoiceLang.detect("tell her no problem") == .en)
        check("en what should i do", VoiceLang.detect("what should i do") == .en)
        check("en pro plan", VoiceLang.detect("about the pro plan") == .en)
        check("fr nos amis", VoiceLang.detect("dis à nos amis que c'est prêt") == .fr)
        check("pt single word is not enough", VoiceLang.detect("obrigado") == .en)
        check("pt pra dizer", VoiceLang.detect("pra dizer que o arquivo está pronto") == .pt)

        print(failures == 0 ? "\nAll voice language tests passed." : "\n\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
