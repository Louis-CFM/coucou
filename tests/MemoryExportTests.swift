import Foundation

@main
enum MemoryExportTests {
    static func main() throws {
        let memory = MemoryRecord(
            id: "m1", text: "Remember tea", factType: .experience, state: .valid,
            context: "preferences", metadata: [
                "coucou.turnId": .string("turn-1"),
                "coucou.platform": .string("macos"),
                "coucou.remoteIds": .string("remote-1"),
                "coucou.hiddenPrompt": .string("hidden prompt"),
                "coucou.rawTool": .string("raw tool"),
                "coucou.authorization": .string("Bearer secret"),
                "coucou.fileContent": .string("private"),
                "coucou.unknown": .string("unknown value"),
                "authorization": .string("Bearer secret"),
                "tool": .object(["raw": .string("hidden")]),
                "fileContent": .string("private"),
            ],
            tags: ["coucou", "coucou:source:chat"], entities: ["Tea"],
            documentId: "document-private", chunkId: "chunk-private",
            createdAt: "2026-10-02T10:00:00Z", sourceFactIds: ["private-source"]
        )
        let json = try MemoryExportFormatter.format([memory], as: .json)
        let jsonAgain = try MemoryExportFormatter.format([memory], as: .json)
        precondition(json == jsonAgain && json.filename == "coucou-memories.json")
        let object = try JSONSerialization.jsonObject(with: Data(json.content.utf8)) as! [[String: Any]]
        precondition(object[0]["id"] as? String == "m1")
        precondition((object[0]["provenance"] as? [String: String])?["coucou.turnId"] == "turn-1")
        precondition((object[0]["provenance"] as? [String: String])?["coucou.remoteIds"] == "remote-1")

        let exportedPage = try MemoryExportFormatter.formatPage(
            MemoryPage(items: [memory], total: 999, limit: 1, offset: 20), as: .json)
        precondition(exportedPage == json, "export must contain only the loaded page and safe fields")

        let markdown = try MemoryExportFormatter.format([memory], as: .markdown)
        precondition(markdown.filename == "coucou-memories.md")
        for expected in ["# Coucou Memories", "## m1", "```\nRemember tea\n```", "- State: `valid`", "- Type: `experience`", "`coucou.turnId`: turn\\-1"] {
            precondition(markdown.content.contains(expected), "missing \(expected)")
        }
        for content in [json.content, markdown.content] {
            for forbidden in ["Bearer secret", "authorization", "hiddenPrompt", "rawTool", "fileContent", "unknown value", "document-private", "chunk-private", "private-source"] {
                precondition(!content.contains(forbidden), "export leaked \(forbidden)")
            }
        }
        var hostile = memory
        hostile.id = "<img src=x onerror=alert(1)>"
        hostile.text = "# injected\n[click](javascript:alert(1))\n```\n<img src=x>"
        hostile.tags = ["![image](https://tracker.invalid/x)"]
        hostile.metadata["coucou.contextLabel"] = .string("</code><script>alert(1)</script>")
        let hostileMarkdown = try MemoryExportFormatter.format([hostile], as: .markdown).content
        precondition(!hostileMarkdown.contains("## <img"))
        precondition(!hostileMarkdown.contains("- Tags: ![image]"))
        precondition(!hostileMarkdown.contains("`coucou.contextLabel`: </code>"))
        precondition(hostileMarkdown.contains("````\n# injected\n[click](javascript:alert(1))\n```\n<img src=x>\n````"))

        let hostileTimestamp = " `![track](https://tracker.invalid/x)<img src=x>``` "
        hostile.createdAt = hostileTimestamp
        hostile.updatedAt = hostileTimestamp
        hostile.mentionedAt = hostileTimestamp
        hostile.occurredStart = hostileTimestamp
        hostile.occurredEnd = hostileTimestamp
        hostile.editedAt = hostileTimestamp
        hostile.metadata["coucou.timestamp"] = .string(hostileTimestamp)
        hostile.metadata["coucou.remoteTimestamp"] = .string(hostileTimestamp)
        let hostileTimestamps = try MemoryExportFormatter.format([hostile], as: .markdown)
        let hostileTimestampsAgain = try MemoryExportFormatter.format([hostile], as: .markdown)
        precondition(hostileTimestamps == hostileTimestampsAgain)
        let safeSpan = "````  `![track](https://tracker.invalid/x)<img src=x>```  ````"
        for label in ["Created", "Updated", "Mentioned", "Occurred start", "Occurred end", "Edited"] {
            precondition(hostileTimestamps.content.contains("- \(label): \(safeSpan)\n"), "unsafe \(label)")
        }
        precondition(hostileTimestamps.content.contains("`coucou.timestamp`: \(safeSpan)"))
        precondition(hostileTimestamps.content.contains("`coucou.remoteTimestamp`: \(safeSpan)"))
        precondition(hostileTimestamps.content.components(separatedBy: hostileTimestamp).count - 1 == 8)

        let exactCredential = "configured-token-value"
        for secret in [
            "AKIAIOSFODNN7EXAMPLE",
            "sk-abcdefghijklmnopqrstuvwxyz",
            "api_key=abcdefghijklmnopqrstuvwxyz",
            "password=correct-horse-battery-staple",
            "token=abcdefghijklmnopqrstuvwxyz",
            "jdbc:postgresql://example.test/private",
            exactCredential,
        ] {
            var secretMemory = memory
            secretMemory.id = "id \(secret)"
            secretMemory.text = "text \(secret)"
            secretMemory.context = "context \(secret)"
            secretMemory.tags = ["tag \(secret)"]
            secretMemory.entities = ["entity \(secret)"]
            secretMemory.createdAt = "created \(secret)"
            secretMemory.metadata["coucou.contextLabel"] = .string("label \(secret)")
            for format in [MemoryExportFormat.json, .markdown] {
                let export = try MemoryExportFormatter.format([secretMemory], as: format, credential: exactCredential)
                precondition(export.content.contains("[REDACTED]"), "missing marker for \(secret)")
                precondition(!export.content.contains(secret), "export leaked \(secret)")
            }
        }
        print("Memory export contract: deterministic safe JSON and Markdown passed")
    }
}
