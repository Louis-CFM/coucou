import Foundation

@main
enum SettingsSearchTests {
    static func main() {
        let w = SettingsSearchMatch.words
        precondition(w("  Réglage   SON ") == ["reglage", "son"])
        precondition(w("   ").isEmpty)

        let sound = (title: "Son", page: "Général", labels: ["Activer les sons", "Volume", "Ouvrir le dossier des sons"])
        func m(_ q: String) -> SettingsSearchMatch? {
            SettingsSearchMatch.match(w(q), title: sound.title, page: sound.page, labels: sound.labels)
        }
        // The box by its title or its page, whatever the accents and the case.
        precondition(m("son") == .box)
        precondition(m("GENERAL") == .box)
        precondition(m("général son") == .box)
        // A setting inside it.
        precondition(m("volu") == .label("Volume"))
        precondition(m("dossier") == .label("Ouvrir le dossier des sons"))
        // Every word somewhere; the label with most of them.
        precondition(m("ouvrir dossier son") == .label("Ouvrir le dossier des sons"))
        precondition(m("volume general") == .label("Volume"))
        // Not there.
        precondition(m("micro") == nil)
        precondition(m("volume micro") == nil, "every word must be found")
        precondition(m("") == nil)
        print("SettingsSearch tests: all passed")
    }
}
