// Minimal stubs for standalone voice test compilation.
// NOT compiled in the app — only used by test-voice-{intent,entity,runner}.sh

import Foundation

enum PillCategory: String, CaseIterable {
    case workspace, agent, ai, service
}

enum AgentSource { case claudeCode, n8n, agent }

struct PillDefinition {
    let id: String
    let name: String
    let defaultColor: String
    let category: PillCategory
    let subtitle: String
    let source: AgentSource
    var comingSoon: Bool = false
    var githubOnly: Bool = false
    var color: String { defaultColor }

    init(id: String, name: String, color: String, category: PillCategory,
         subtitle: String, source: AgentSource,
         comingSoon: Bool = false, githubOnly: Bool = false) {
        self.id           = id
        self.name         = name
        self.defaultColor = color
        self.category     = category
        self.subtitle     = subtitle
        self.source       = source
        self.comingSoon   = comingSoon
        self.githubOnly   = githubOnly
    }
}
