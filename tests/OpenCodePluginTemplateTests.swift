import Foundation

@main
enum OpenCodePluginTemplateTests {
    static func main() {
        let content = OpenCodePluginTemplate.build(
            hookScriptPath: "/Users/me/Library/Application Support/NotchBuddy/nb-hook")

        // OpenCode 2 refuses a plugin without a default definition carrying an
        // id and a setup function ("Plugin must export a default definition…").
        precondition(content.contains("export default {"))
        precondition(content.contains("id: 'coucou'"))
        precondition(content.contains("async setup(ctx)"))

        // OpenCode 1 still loads the named export (dual export).
        precondition(content.contains("export const CoucouPlugin"))

        // V2 event map: the types OpenCode 2.0.29 actually emits.
        precondition(content.contains("'session.created': 'SessionStart'"))
        precondition(content.contains("'session.execution.started': 'UserPromptSubmit'"))
        precondition(content.contains("'session.execution.succeeded': 'Stop'"))
        precondition(content.contains("'session.execution.failed': 'StopFailure'"))

        // The 1.x types must appear exactly once — in the V1 map only. On
        // OpenCode 2 they never fire, so mapping them in V2_EVENTS would mean
        // Stop is never forwarded.
        precondition(content.components(separatedBy: "'session.idle'").count - 1 == 1)
        precondition(content.components(separatedBy: "'session.deleted'").count - 1 == 1)

        // OpenCode 2 loads one plugin instance per location and each sees the
        // global event stream: session events must be deduplicated by event id
        // through atomic claim files, or every event is forwarded N times.
        precondition(content.contains("function claimEvent(eventID)"))
        precondition(content.contains("'wx'"))
        precondition(content.contains("ctx.event.subscribe"))

        // Tool hooks feed the island ticker; they run once per owning runtime.
        precondition(content.contains("ctx.tool.hook('execute.before'"))
        precondition(content.contains("ctx.tool.hook('execute.after'"))

        // Fire-and-forget: the plugin must never answer for OpenCode.
        precondition(!content.contains("permissionDecision"))

        // The hook path is embedded.
        precondition(content.contains("const HOOK = '/Users/me/Library/Application Support/NotchBuddy/nb-hook';"))

        // Paths with a quote or a backslash are escaped, not broken.
        let tricky = OpenCodePluginTemplate.build(hookScriptPath: "/opt/we'ird\\path/nb-hook")
        precondition(tricky.contains("const HOOK = '/opt/we\\'ird\\\\path/nb-hook';"))

        // The installed-check in HookServer looks for these markers.
        precondition(content.contains("nb-hook"))
        precondition(content.contains("opencode"))

        print("OpenCodePluginTemplateTests: all assertions passed")
    }
}
