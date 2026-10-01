import Foundation
import Combine
import XCTest
@testable import Coucou

final class AgentSessionReducerTests: XCTestCase {
    func testRuntimeSessionTasksKeepClaudeAndCodexIdentitiesSeparate() {
        let timestamp = Date(timeIntervalSince1970: 2_000)
        let claude = AgentSession(
            id: "claude-code:shared-native-id",
            runtime: .claudeCode,
            provider: .anthropic,
            nativeSessionID: "shared-native-id",
            workspace: URL(fileURLWithPath: "/tmp/claude-project"),
            state: .working,
            model: nil,
            latestActivity: AgentActivity(
                id: UUID(),
                title: "Editing files",
                detail: nil,
                startedAt: timestamp,
                completedAt: nil
            ),
            pendingApproval: nil,
            pendingUserInput: nil,
            startedAt: timestamp,
            updatedAt: timestamp,
            metadata: [:]
        )
        let codex = AgentSession(
            id: "codex:shared-native-id",
            runtime: .codex,
            provider: .openAI,
            nativeSessionID: "shared-native-id",
            workspace: URL(fileURLWithPath: "/tmp/codex-project"),
            state: .waitingForApproval,
            model: nil,
            latestActivity: nil,
            pendingApproval: AgentApprovalRequest(
                id: "approval-1",
                title: "Run tests",
                detail: "swift test",
                tool: nil,
                choices: [.allow, .deny]
            ),
            pendingUserInput: nil,
            startedAt: timestamp,
            updatedAt: timestamp,
            metadata: [:]
        )

        let claudeTask = AgentTask(runtimeSession: claude)
        let codexTask = AgentTask(runtimeSession: codex)

        XCTAssertNotEqual(claudeTask.id, codexTask.id)
        XCTAssertEqual(claudeTask.agentSessionID, "claude-code:shared-native-id")
        XCTAssertEqual(claudeTask.source, .claudeCode)
        XCTAssertEqual(claudeTask.name, "claude-project")
        XCTAssertEqual(claudeTask.steps, ["Editing files"])
        XCTAssertEqual(codexTask.agentSessionID, "codex:shared-native-id")
        XCTAssertEqual(codexTask.source, .codex)
        XCTAssertEqual(codexTask.name, "codex-project")
        XCTAssertEqual(codexTask.state, .approval)
        XCTAssertEqual(codexTask.pillBadge, .approval)
    }

    func testGeminiHookTranslatorUsesOfficialLifecycleAndToolFields() throws {
        let started = try XCTUnwrap(GeminiHookTranslator.translate(payload: [
            "hook_event_name": "SessionStart",
            "session_id": "gemini-session-1",
            "cwd": "/tmp/gemini-project",
            "source": "resume",
            "timestamp": "2026-10-01T10:00:00Z",
        ]))
        XCTAssertEqual(started.event.runtime, .geminiCLI)
        XCTAssertEqual(started.event.provider, .google)
        XCTAssertEqual(started.event.kind, .sessionResumed)
        XCTAssertEqual(started.event.metadata["geminiHookName"], .string("SessionStart"))
        XCTAssertEqual(started.projectName, "gemini-project")

        let beforeTool = try XCTUnwrap(GeminiHookTranslator.translate(payload: [
            "hook_event_name": "BeforeTool",
            "session_id": "gemini-session-1",
            "cwd": "/tmp/gemini-project",
            "tool_name": "run_shell_command",
            "tool_input": ["command": "swift test"],
            "timestamp": "2026-10-01T10:00:01Z",
        ]))
        XCTAssertEqual(beforeTool.event.kind, .toolStarted)
        XCTAssertEqual(beforeTool.event.tool?.name, "run_shell_command")
        XCTAssertEqual(beforeTool.event.tool?.input["command"], .string("swift test"))
        XCTAssertEqual(beforeTool.event.metadata["nativeToolName"], .string("run_shell_command"))
    }

    func testGeminiAfterToolPreservesFailureAndProviderMetadata() throws {
        let event = try XCTUnwrap(GeminiHookTranslator.translate(payload: [
            "hook_event_name": "AfterTool",
            "session_id": "gemini-session-2",
            "cwd": "/tmp/project",
            "tool_name": "write_file",
            "tool_input": ["file_path": "/tmp/project/a.swift"],
            "tool_response": ["error": "permission denied"],
            "timestamp": "2026-10-01T10:00:02Z",
        ])).event

        XCTAssertEqual(event.kind, .toolFailed)
        XCTAssertEqual(event.metadata["nativePayloadVersion"], .string("hooks-v1"))
        XCTAssertEqual(event.metadata["nativeEventID"], .string("AfterTool:2026-10-01T10:00:02Z"))
        XCTAssertTrue(event.detail?.contains("permission denied") == true)
    }

    func testGeminiHookMergePreservesUserSettingsAndReplacesOnlyCoucouEntry() throws {
        let existing: [String: Any] = [
            "theme": "GitHub",
            "hooks": [
                "BeforeTool": [
                    ["hooks": [["type": "command", "command": "other-observer"]]],
                    ["hooks": [[
                        "type": "command",
                        "command": "COUCOU_RUNTIME=gemini-cli /old/coucou-hook",
                    ]]],
                ],
                "CustomEvent": [["hooks": [["type": "command", "command": "keep-me"]]]],
            ],
        ]

        let merged = HookServer.mergingGeminiHooks(
            into: existing,
            command: "COUCOU_RUNTIME=gemini-cli /new/nb-hook"
        )

        XCTAssertEqual(merged["theme"] as? String, "GitHub")
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["CustomEvent"])
        let beforeTool = try XCTUnwrap(hooks["BeforeTool"] as? [[String: Any]])
        let commands = beforeTool.flatMap { group in
            (group["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
        }
        XCTAssertTrue(commands.contains("other-observer"))
        XCTAssertTrue(commands.contains("COUCOU_RUNTIME=gemini-cli /new/nb-hook"))
        XCTAssertFalse(commands.contains(where: { $0.contains("/old/coucou-hook") }))
        XCTAssertNotNil(hooks["AfterAgent"])
        XCTAssertNotNil(hooks["SessionEnd"])
    }

    func testAntigravityHookTranslatorUsesOfficialConversationAndToolFields() throws {
        let started = try XCTUnwrap(AntigravityHookTranslator.translate(payload: [
            "hook_event_name": "PreInvocation",
            "conversationId": "agy-conversation-1",
            "workspacePaths": ["/tmp/antigravity-project"],
            "modelName": "gemini-3.6-flash-medium",
            "invocationNum": 0,
            "initialNumSteps": 0,
        ]))
        XCTAssertEqual(started.event.runtime, .antigravity)
        XCTAssertEqual(started.event.provider, .google)
        XCTAssertEqual(started.event.kind, .sessionStarted)
        XCTAssertEqual(started.event.sessionID, "agy-conversation-1")
        XCTAssertEqual(started.event.metadata["modelName"], .string("gemini-3.6-flash-medium"))
        XCTAssertEqual(started.projectName, "antigravity-project")

        let tool = try XCTUnwrap(AntigravityHookTranslator.translate(payload: [
            "hook_event_name": "PostToolUse",
            "conversationId": "agy-conversation-1",
            "workspacePaths": ["/tmp/antigravity-project"],
            "toolCall": [
                "name": "run_command",
                "args": ["CommandLine": "swift test", "Cwd": "/tmp/antigravity-project"],
            ],
            "stepIdx": 4,
            "error": "",
        ]))
        XCTAssertEqual(tool.event.kind, .toolCompleted)
        XCTAssertEqual(tool.event.tool?.name, "run_command")
        XCTAssertEqual(tool.event.tool?.input["CommandLine"], .string("swift test"))
        XCTAssertEqual(tool.event.metadata["nativeEventID"], .string("PostToolUse:run_command:4"))
    }

    func testAntigravityStopPreservesFailureAndCompletion() throws {
        let failed = try XCTUnwrap(AntigravityHookTranslator.translate(payload: [
            "hook_event_name": "Stop",
            "conversationId": "agy-conversation-2",
            "workspacePaths": ["/tmp/project"],
            "executionNum": 1,
            "terminationReason": "error",
            "error": "model unavailable",
            "fullyIdle": true,
        ])).event
        XCTAssertEqual(failed.kind, .error)
        XCTAssertEqual(failed.detail, "model unavailable")

        let completed = try XCTUnwrap(AntigravityHookTranslator.translate(payload: [
            "hook_event_name": "Stop",
            "conversationId": "agy-conversation-2",
            "workspacePaths": ["/tmp/project"],
            "executionNum": 2,
            "terminationReason": "model_stop",
            "fullyIdle": true,
        ])).event
        XCTAssertEqual(completed.kind, .completed)
    }

    func testAntigravityHookMergePreservesUnrelatedHooksAndDoesNotAffectPermissions() throws {
        let existing: [String: Any] = [
            "team-linter": [
                "PostToolUse": [[
                    "matcher": "write_to_file",
                    "hooks": [["type": "command", "command": "run-linter"]],
                ]],
            ],
            "old-coucou": [
                "Stop": [[
                    "type": "command",
                    "command": "COUCOU_RUNTIME=antigravity /old/nb-hook",
                ]],
            ],
        ]

        let merged = HookServer.mergingAntigravityHooks(
            into: existing,
            commandPath: "\"/new/nb-hook\""
        )

        XCTAssertNotNil(merged["team-linter"])
        XCTAssertNil(merged["old-coucou"])
        let coucou = try XCTUnwrap(merged["coucou-agent-observer"] as? [String: Any])
        XCTAssertNil(coucou["PreToolUse"], "An observer must not override native permission decisions")
        XCTAssertNotNil(coucou["PostToolUse"])
        XCTAssertNotNil(coucou["PreInvocation"])
        XCTAssertNotNil(coucou["PostInvocation"])
        XCTAssertNotNil(coucou["Stop"])
        let encoded = try JSONSerialization.data(withJSONObject: coucou)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("COUCOU_RUNTIME=antigravity"))
        XCTAssertTrue(text.contains("COUCOU_HOOK_EVENT=Stop"))
    }

    func testOpenAIModelCatalogFiltersNonChatModelsAndAddsCapabilities() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "data": [
                ["id": "gpt-5.6-sol"],
                ["id": "gpt-image-2"],
                ["id": "text-embedding-3-small"],
                ["id": "o4-mini"],
            ],
        ])
        let models = try OpenAIProvider.decodeModels(data)

        XCTAssertEqual(models.map(\.id), ["gpt-5.6-sol", "o4-mini"])
        XCTAssertTrue(models.allSatisfy { $0.provider == .openAI })
        XCTAssertEqual(models.first?.reasoningOptions.map(\.id), ["low", "medium", "high"])
        XCTAssertEqual(models.first?.metadata["catalogSource"], "provider-api")
    }

    func testOpenAIResponseDecodesOutputTextAndUsage() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "resp_123",
            "status": "completed",
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": "  Olá  "]],
            ]],
            "usage": ["input_tokens": 20, "output_tokens": 5],
        ])
        let response = try OpenAIProvider.decodeResponse(data)

        XCTAssertEqual(response.message.content, "Olá")
        XCTAssertEqual(response.finishReason, "completed")
        XCTAssertEqual(response.metadata["responseID"], .string("resp_123"))
        XCTAssertEqual(response.metadata["inputTokens"], .number(20))
        XCTAssertEqual(response.metadata["outputTokens"], .number(5))
    }

    func testGeminiModelCatalogUsesProviderModelsAndThinkingCapabilities() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "models": [
                [
                    "name": "models/gemini-3-flash-preview",
                    "displayName": "Gemini 3 Flash",
                    "supportedGenerationMethods": ["generateContent"],
                    "inputTokenLimit": 1_000_000,
                    "outputTokenLimit": 65_536,
                ],
                [
                    "name": "models/text-embedding-004",
                    "supportedGenerationMethods": ["embedContent"],
                ],
            ],
        ])

        let models = try GeminiProvider.decodeModels(data)

        XCTAssertEqual(models.map(\.id), ["gemini-3-flash-preview"])
        XCTAssertEqual(models.first?.provider, .google)
        XCTAssertEqual(models.first?.displayName, "Gemini 3 Flash")
        XCTAssertEqual(models.first?.reasoningOptions.map(\.id), ["low", "medium", "high"])
        XCTAssertEqual(models.first?.contextWindow, 1_000_000)
        XCTAssertEqual(models.first?.maxOutputTokens, 65_536)
        XCTAssertEqual(models.first?.metadata["catalogSource"], "provider-api")
    }

    func testGeminiResponseIgnoresThoughtSummaryAndKeepsUsage() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "responseId": "gemini-response-1",
            "modelVersion": "gemini-3-flash-preview",
            "candidates": [[
                "finishReason": "STOP",
                "content": ["parts": [
                    ["thought": true, "text": "Internal summary"],
                    ["text": "  Final answer  "],
                ]],
            ]],
            "usageMetadata": [
                "promptTokenCount": 14,
                "candidatesTokenCount": 6,
                "thoughtsTokenCount": 9,
            ],
        ])

        let response = try GeminiProvider.decodeResponse(data)

        XCTAssertEqual(response.message.content, "Final answer")
        XCTAssertEqual(response.finishReason, "STOP")
        XCTAssertEqual(response.metadata["responseID"], .string("gemini-response-1"))
        XCTAssertEqual(response.metadata["inputTokens"], .number(14))
        XCTAssertEqual(response.metadata["outputTokens"], .number(6))
        XCTAssertEqual(response.metadata["thinkingTokens"], .number(9))
    }

    func testGeminiRequestUsesNativeRolesSearchAndThinkingLevel() throws {
        let provider = GeminiProvider(apiKey: { "test-key" })
        let body = try provider.requestBody(
            for: ChatRequest(
                modelID: "gemini-3-flash-preview",
                messages: [
                    AIChatMessage(id: UUID(), role: .user, content: "Question"),
                    AIChatMessage(id: UUID(), role: .assistant, content: "Answer"),
                ],
                systemPrompt: "Be helpful",
                reasoning: ReasoningSelection(optionID: "high", providerValue: "level:high"),
                attachments: [],
                tools: [],
                webSearch: true,
                maxOutputTokens: 2_048
            )
        )

        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model"])
        let generation = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        let thinking = try XCTUnwrap(generation["thinkingConfig"] as? [String: Any])
        XCTAssertEqual(thinking["thinkingLevel"] as? String, "high")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertNotNil(tools.first?["google_search"])
    }

    func testAnthropicFallbackCatalogKeepsProviderSpecificModelData() async throws {
        let provider = AnthropicProvider(apiKey: { "test-key" })
        let models = try await provider.listModels(forceRefresh: false)

        XCTAssertEqual(models.map(\.provider), [.anthropic])
        XCTAssertEqual(models.map(\.id), [AnthropicProvider.defaultModelID])
        XCTAssertEqual(models.first?.metadata["catalogSource"], "compatibility-fallback")
    }

    func testAnthropicResponseDecodesTextAndUsageWithoutRawPayload() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": "  Bonjour  "]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 12, "output_tokens": 4],
        ])
        let response = try AnthropicProvider.decodeResponse(data)

        XCTAssertEqual(response.message.role, .assistant)
        XCTAssertEqual(response.message.content, "Bonjour")
        XCTAssertEqual(response.finishReason, "end_turn")
        XCTAssertEqual(response.metadata["inputTokens"], .number(12))
        XCTAssertEqual(response.metadata["outputTokens"], .number(4))
    }

    @MainActor
    func testClaudeAdapterFeedsNormalizedRuntimeManagerSession() async throws {
        let adapter = ClaudeCodeAgentRuntimeAdapter(approvalHandler: { _ in })
        let manager = AgentRuntimeManager(adapters: [adapter])
        await manager.start()
        let sessionReceived = expectation(description: "Claude session reaches normalized manager")
        var didReceiveSession = false
        let cancellable = manager.$sessions
            .dropFirst()
            .sink { sessions in
                if !didReceiveSession, sessions["claude-code:claude-1"] != nil {
                    didReceiveSession = true
                    sessionReceived.fulfill()
                }
            }

        let translation = try XCTUnwrap(
            ClaudeHookTranslator.translate(
                name: "SessionStart",
                payload: [
                    "session_id": "claude-1",
                    "cwd": "/tmp/notch-buddy",
                    "term_program": "vscode",
                ]
            )
        )
        manager.ingestExternal(translation.event)

        await fulfillment(of: [sessionReceived], timeout: 2)
        withExtendedLifetime(cancellable) {}
        let session = try XCTUnwrap(manager.sessions["claude-code:claude-1"])
        XCTAssertEqual(session.runtime, .claudeCode)
        XCTAssertEqual(session.provider, .anthropic)
        XCTAssertEqual(session.workspace?.path, "/tmp/notch-buddy")
        XCTAssertEqual(session.state, .working)
        await manager.stop()
    }

    @MainActor
    func testClaudeApprovalRoutesThroughAdapterWithExactRequest() async throws {
        var resolvedDecision: ApprovalDecision?
        let adapter = ClaudeCodeAgentRuntimeAdapter { resolvedDecision = $0 }
        let manager = AgentRuntimeManager(adapters: [adapter])
        await manager.start()
        let approvalReceived = expectation(description: "Claude approval reaches normalized manager")
        let cancellable = manager.$latestAttentionSessionID
            .dropFirst()
            .sink { sessionID in
                if sessionID == "claude-code:claude-approval" { approvalReceived.fulfill() }
            }
        let translation = try XCTUnwrap(
            ClaudeHookTranslator.translate(
                name: "PermissionRequest",
                payload: [
                    "session_id": "claude-approval",
                    "request_id": "approval-7",
                    "cwd": "/tmp/project",
                    "tool_name": "Bash",
                    "tool_input": ["command": "swift test"],
                ]
            )
        )
        manager.ingestExternal(translation.event)
        await fulfillment(of: [approvalReceived], timeout: 2)
        withExtendedLifetime(cancellable) {}

        try await manager.resolveApproval(
            sessionID: "claude-code:claude-approval",
            requestID: "approval-7",
            decision: .allowForSession
        )
        XCTAssertEqual(resolvedDecision, .allowForSession)
        await manager.stop()
    }

    @MainActor
    func testRuntimeManagerLoadsModelsAndStoresStartedSession() async throws {
        let adapter = FakeAgentRuntimeAdapter()
        let manager = AgentRuntimeManager(adapters: [adapter])
        await manager.start()

        XCTAssertEqual(manager.models[.codex]?.map(\.id), ["gpt-test"])
        let request = StartAgentSessionRequest(
            workspace: URL(fileURLWithPath: "/tmp/project"),
            prompt: "Implement the feature",
            model: ModelSelection(modelID: "gpt-test", reasoningOptionID: "high"),
            metadata: [:]
        )
        let session = try await manager.startSession(runtimeID: .codex, request: request)

        XCTAssertEqual(adapter.startedRequest, request)
        XCTAssertEqual(session.id, "codex:started-thread")
        XCTAssertEqual(manager.sessions[session.id]?.model?.modelID, "gpt-test")

        _ = try await manager.resumeSession(sessionID: session.id)
        XCTAssertEqual(adapter.resumedNativeSessionID, "started-thread")
        await manager.stop()
    }

    @MainActor
    func testSendingPromptToSavedSessionResumesBeforeStartingTurn() async throws {
        let adapter = FakeAgentRuntimeAdapter()
        let timestamp = Date(timeIntervalSince1970: 2_000)
        adapter.listedSessions = [
            AgentSession(
                id: "codex:saved-thread",
                runtime: .codex,
                provider: .openAI,
                nativeSessionID: "saved-thread",
                workspace: URL(fileURLWithPath: "/tmp/project"),
                state: .disconnected,
                model: ModelSelection(modelID: "gpt-test", reasoningOptionID: "high"),
                latestActivity: nil,
                pendingApproval: nil,
                pendingUserInput: nil,
                startedAt: timestamp,
                updatedAt: timestamp,
                metadata: [:]
            ),
        ]
        let manager = AgentRuntimeManager(adapters: [adapter])
        await manager.start()

        try await manager.sendPrompt(sessionID: "codex:saved-thread", prompt: "Continue")

        XCTAssertEqual(adapter.calls, ["resume:saved-thread", "send:saved-thread"])
        XCTAssertEqual(adapter.sentPrompt, "Continue")
        XCTAssertEqual(manager.sessions["codex:saved-thread"]?.state, .working)
        XCTAssertEqual(manager.conversations["codex:saved-thread"]?.last?.content, "Continue")
        await manager.stop()
    }

    @MainActor
    func testRuntimeManagerPublishesDisconnectedRuntimeStatus() async throws {
        let adapter = FakeAgentRuntimeAdapter()
        let manager = AgentRuntimeManager(adapters: [adapter])
        await manager.start()
        let disconnected = expectation(description: "Disconnected runtime status is published")
        let cancellable = manager.$availability.sink { availability in
            if case .disconnected = availability[.codex] { disconnected.fulfill() }
        }

        adapter.emitStatus(.disconnected(version: "test", reason: "reconnecting"))
        await fulfillment(of: [disconnected], timeout: 2)

        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(
            manager.availability[.codex],
            .disconnected(version: "test", reason: "reconnecting")
        )
        await manager.stop()
    }

    @MainActor
    func testRuntimeManagerRoutesApprovalToExactCodexSession() async throws {
        let adapter = FakeAgentRuntimeAdapter()
        let manager = AgentRuntimeManager(adapters: [adapter])
        await manager.start()
        let attentionReceived = expectation(description: "Codex approval becomes active")
        let cancellable = manager.$latestAttentionSessionID
            .dropFirst()
            .sink { sessionID in
                if sessionID == "codex:thread-1" { attentionReceived.fulfill() }
            }

        adapter.emit(
            AgentEvent(
                id: UUID(),
                runtime: .codex,
                provider: .openAI,
                sessionID: "thread-1",
                timestamp: Date(timeIntervalSince1970: 2_000),
                kind: .approvalRequested,
                title: "Run command",
                detail: "swift test",
                tool: nil,
                approval: AgentApprovalRequest(
                    id: "request-42",
                    title: "Run command",
                    detail: "swift test",
                    tool: nil,
                    choices: [.allow, .deny]
                ),
                userInput: nil,
                metadata: [:]
            )
        )
        await fulfillment(of: [attentionReceived], timeout: 2)
        withExtendedLifetime(cancellable) {}

        XCTAssertEqual(manager.latestAttentionSessionID, "codex:thread-1")
        XCTAssertEqual(manager.sessions["codex:thread-1"]?.state, .waitingForApproval)

        try await manager.resolveApproval(
            sessionID: "codex:thread-1",
            requestID: "request-42",
            decision: .allow
        )
        XCTAssertEqual(adapter.resolvedSessionID, "thread-1")
        XCTAssertEqual(adapter.resolvedRequestID, "request-42")
        XCTAssertEqual(adapter.resolvedDecision, .allow)

        do {
            try await manager.resolveApproval(
                sessionID: "codex:thread-1",
                requestID: "stale-request",
                decision: .allow
            )
            XCTFail("A stale approval request must not reach the runtime")
        } catch {
            XCTAssertEqual(error as? AgentRuntimeError, .staleRequest)
        }
        XCTAssertEqual(adapter.resolvedRequestID, "request-42")
        await manager.stop()
    }

    func testCodexThreadStartedUsesNestedThreadID() {
        let event = CodexAppServerEventTranslator.translate(
            [
                "method": "thread/started",
                "params": [
                    "thread": ["id": "thr_nested", "name": "Feature"],
                ],
            ]
        )

        XCTAssertEqual(event?.sessionID, "thr_nested")
        XCTAssertEqual(event?.kind, .sessionStarted)
    }

    func testCodexModelCatalogUsesRuntimeCapabilities() {
        let models = CodexAppServerCodec.models(from: .object([
            "data": .array([.object([
                "id": .string("gpt-test"),
                "model": .string("gpt-test"),
                "displayName": .string("GPT Test"),
                "hidden": .bool(false),
                "defaultReasoningEffort": .string("medium"),
                "supportedReasoningEfforts": .array([
                    .object([
                        "reasoningEffort": .string("low"),
                        "description": .string("Fast"),
                    ]),
                    .object([
                        "reasoningEffort": .string("high"),
                        "description": .string("Deep"),
                    ]),
                ]),
                "inputModalities": .array([.string("text"), .string("image")]),
            ])]),
        ]))

        XCTAssertEqual(models.map(\.id), ["gpt-test"])
        XCTAssertEqual(models.first?.reasoningOptions.map(\.id), ["low", "high"])
        XCTAssertEqual(models.first?.capabilities.vision, true)
    }

    func testCodexThreadBecomesNormalizedSession() {
        let sessions = CodexAppServerCodec.sessions(from: .object([
            "data": .array([.object([
                "id": .string("thr_123"),
                "cwd": .string("/tmp/project"),
                "createdAt": .number(1_700_000_000),
                "updatedAt": .number(1_700_000_100),
                "model": .string("gpt-test"),
                "reasoningEffort": .string("high"),
                "modelProvider": .string("openai"),
                "preview": .string("Implement feature"),
                "status": .object(["type": .string("active")]),
            ])]),
        ]))

        XCTAssertEqual(sessions.first?.id, "codex:thr_123")
        XCTAssertEqual(sessions.first?.state, .working)
        XCTAssertEqual(sessions.first?.workspace?.path, "/tmp/project")
        XCTAssertEqual(sessions.first?.model?.reasoningOptionID, "high")
    }

    func testCodexApprovalUsesJSONRPCRequestIDAndThreadScope() {
        let event = CodexAppServerEventTranslator.translate(
            [
                "method": "item/commandExecution/requestApproval",
                "id": 42,
                "params": [
                    "threadId": "thr_123",
                    "turnId": "turn_456",
                    "itemId": "item_789",
                    "startedAtMs": 1_750_000_000_000,
                    "command": "swift test",
                    "cwd": "/tmp/project",
                ],
            ]
        )

        XCTAssertEqual(event?.runtime, .codex)
        XCTAssertEqual(event?.sessionID, "thr_123")
        XCTAssertEqual(event?.kind, .approvalRequested)
        XCTAssertEqual(event?.approval?.id, "42")
        XCTAssertEqual(event?.approval?.detail, "swift test")
    }

    func testCodexApprovalHonorsAvailableDecisionsAndNetworkContext() {
        let event = CodexAppServerEventTranslator.translate(
            [
                "method": "item/commandExecution/requestApproval",
                "id": 7,
                "params": [
                    "threadId": "thr_network",
                    "turnId": "turn_network",
                    "itemId": "item_network",
                    "networkApprovalContext": ["host": "api.example.com"],
                    "availableDecisions": ["accept", "decline"],
                ],
            ]
        )

        XCTAssertEqual(event?.approval?.title, "Access network")
        XCTAssertEqual(event?.approval?.detail, "api.example.com")
        XCTAssertEqual(event?.approval?.choices, [.allow, .deny])
    }

    func testCodexUserInputKeepsQuestionsAndJSONRPCRequestID() {
        let event = CodexAppServerEventTranslator.translate(
            [
                "method": "item/tool/requestUserInput",
                "id": 91,
                "params": [
                    "threadId": "thr_input",
                    "turnId": "turn_input",
                    "itemId": "item_input",
                    "isBlocking": true,
                    "questions": [
                        [
                            "id": "database",
                            "header": "Storage",
                            "question": "Which database should be used?",
                            "isOther": true,
                            "isSecret": false,
                            "options": [
                                ["label": "Postgres", "description": "Relational database"],
                                ["label": "SQLite", "description": "Local database"],
                            ],
                        ],
                    ],
                ],
            ]
        )

        XCTAssertEqual(event?.kind, .userInputRequested)
        XCTAssertEqual(event?.title, "Which database should be used?")
        XCTAssertEqual(event?.userInput?.id, "91")
        XCTAssertEqual(event?.userInput?.itemID, "item_input")
        XCTAssertEqual(event?.userInput?.questions.first?.id, "database")
        XCTAssertEqual(event?.userInput?.questions.first?.options.map(\.label), ["Postgres", "SQLite"])
        XCTAssertEqual(event?.userInput?.questions.first?.allowsOther, true)
    }

    @MainActor
    func testRuntimeManagerRoutesUserInputToExactCodexRequest() async throws {
        let adapter = FakeAgentRuntimeAdapter()
        let manager = AgentRuntimeManager(adapters: [adapter])
        await manager.start()
        let attentionReceived = expectation(description: "Codex input becomes active")
        let cancellable = manager.$latestAttentionSessionID
            .dropFirst()
            .sink { sessionID in
                if sessionID == "codex:thread-input" { attentionReceived.fulfill() }
            }
        let request = AgentUserInputRequest(
            id: "request-input",
            itemID: "item-input",
            questions: [
                AgentUserInputQuestion(
                    id: "database",
                    header: "Storage",
                    question: "Which database?",
                    options: [],
                    allowsOther: true,
                    isSecret: false
                ),
            ],
            isBlocking: true
        )
        adapter.emit(
            AgentEvent(
                id: UUID(),
                runtime: .codex,
                provider: .openAI,
                sessionID: "thread-input",
                timestamp: Date(timeIntervalSince1970: 2_000),
                kind: .userInputRequested,
                title: "Which database?",
                detail: "Storage",
                tool: nil,
                approval: nil,
                userInput: request,
                metadata: [:]
            )
        )
        await fulfillment(of: [attentionReceived], timeout: 2)
        withExtendedLifetime(cancellable) {}

        try await manager.respondToUserInput(
            sessionID: "codex:thread-input",
            requestID: "request-input",
            answers: ["database": ["Postgres"]]
        )

        XCTAssertEqual(manager.sessions["codex:thread-input"]?.pendingUserInput?.id, "request-input")
        XCTAssertEqual(adapter.inputSessionID, "thread-input")
        XCTAssertEqual(adapter.inputRequestID, "request-input")
        XCTAssertEqual(adapter.inputAnswers, ["database": ["Postgres"]])

        do {
            try await manager.respondToUserInput(
                sessionID: "codex:thread-input",
                requestID: "stale-request",
                answers: ["database": ["SQLite"]]
            )
            XCTFail("A stale input request must not reach the runtime")
        } catch {
            XCTAssertEqual(error as? AgentRuntimeError, .staleRequest)
        }
        XCTAssertEqual(adapter.inputRequestID, "request-input")
        XCTAssertEqual(adapter.inputAnswers, ["database": ["Postgres"]])
        await manager.stop()
    }

    func testInterruptedCodexTurnBecomesCancelled() {
        let event = CodexAppServerEventTranslator.translate(
            [
                "method": "turn/completed",
                "params": [
                    "threadId": "thr_123",
                    "turn": ["id": "turn_456", "status": "interrupted"],
                ],
            ]
        )

        XCTAssertEqual(event?.kind, .cancelled)
    }

    func testClaudeToolEventTranslatesWithoutLeakingNativePayload() {
        let translation = ClaudeHookTranslator.translate(
            name: "PreToolUse",
            payload: [
                "session_id": "claude-1",
                "cwd": "/tmp/notch-buddy",
                "tool_name": "Read",
                "tool_input": ["file_path": "/tmp/notch-buddy/README.md"],
            ],
            timestamp: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(translation?.event.runtime, .claudeCode)
        XCTAssertEqual(translation?.event.provider, .anthropic)
        XCTAssertEqual(translation?.event.kind, .toolStarted)
        XCTAssertEqual(translation?.event.title, "Lit · README.md")
        XCTAssertEqual(translation?.projectName, "Notch Buddy")
    }

    func testClaudeQuestionNotificationBecomesUserInputRequest() {
        let translation = ClaudeHookTranslator.translate(
            name: "Notification",
            payload: [
                "session_id": "claude-1",
                "message": "Continue?",
            ]
        )

        XCTAssertEqual(translation?.event.kind, .userInputRequested)
        XCTAssertEqual(translation?.event.title, "Continue?")
    }

    func testApprovalLifecycleKeepsSessionIdentity() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var session = AgentSession(
            id: "codex:session-1",
            runtime: .codex,
            provider: .openAI,
            nativeSessionID: "session-1",
            workspace: URL(fileURLWithPath: "/tmp/project"),
            state: .starting,
            model: nil,
            latestActivity: nil,
            pendingApproval: nil,
            pendingUserInput: nil,
            startedAt: startedAt,
            updatedAt: startedAt,
            metadata: [:]
        )
        let approval = AgentApprovalRequest(
            id: "approval-1",
            title: "Run command",
            detail: "swift test",
            tool: nil,
            choices: [.allow, .deny]
        )

        AgentSessionReducer.reduce(
            &session,
            event: event(kind: .approvalRequested, approval: approval)
        )
        XCTAssertEqual(session.state, .waitingForApproval)
        XCTAssertEqual(session.pendingApproval?.id, "approval-1")

        AgentSessionReducer.reduce(
            &session,
            event: event(kind: .approvalResolved)
        )
        XCTAssertEqual(session.state, .working)
        XCTAssertNil(session.pendingApproval)
    }

    func testDelayedActivityCannotReopenCompletedSession() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var session = AgentSession(
            id: "codex:session-1",
            runtime: .codex,
            provider: .openAI,
            nativeSessionID: "session-1",
            workspace: nil,
            state: .working,
            model: nil,
            latestActivity: nil,
            pendingApproval: nil,
            pendingUserInput: nil,
            startedAt: startedAt,
            updatedAt: startedAt,
            metadata: [:]
        )

        AgentSessionReducer.reduce(&session, event: event(kind: .completed))
        AgentSessionReducer.reduce(&session, event: event(kind: .toolStarted))

        XCTAssertEqual(session.state, .completed)
    }

    func testActivityCannotHidePendingApproval() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let approval = AgentApprovalRequest(
            id: "approval-pending",
            title: "Run command",
            detail: nil,
            tool: nil,
            choices: [.allow, .deny]
        )
        var session = AgentSession(
            id: "codex:session-1",
            runtime: .codex,
            provider: .openAI,
            nativeSessionID: "session-1",
            workspace: nil,
            state: .working,
            model: nil,
            latestActivity: nil,
            pendingApproval: nil,
            pendingUserInput: nil,
            startedAt: startedAt,
            updatedAt: startedAt,
            metadata: [:]
        )

        AgentSessionReducer.reduce(
            &session,
            event: event(kind: .approvalRequested, approval: approval)
        )
        AgentSessionReducer.reduce(&session, event: event(kind: .toolCompleted))

        XCTAssertEqual(session.state, .waitingForApproval)
        XCTAssertEqual(session.pendingApproval?.id, "approval-pending")
    }

    @MainActor
    func testOlderCodexSequenceCannotRegressSession() async throws {
        let adapter = FakeAgentRuntimeAdapter()
        let manager = AgentRuntimeManager(adapters: [adapter])
        await manager.start()
        let completed = expectation(description: "Latest sequence completes session")
        let cancellable = manager.$sessions.sink { sessions in
            if sessions["codex:sequenced"]?.state == .completed { completed.fulfill() }
        }

        adapter.emit(sequencedEvent(sessionID: "sequenced", sequence: 2, kind: .completed))
        await fulfillment(of: [completed], timeout: 2)
        adapter.emit(sequencedEvent(sessionID: "sequenced", sequence: 1, kind: .toolStarted))
        await Task.yield()

        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(manager.sessions["codex:sequenced"]?.state, .completed)
        await manager.stop()
    }

    @MainActor
    func testResolvingLatestApprovalRevealsOtherPendingSession() async throws {
        let adapter = FakeAgentRuntimeAdapter()
        let manager = AgentRuntimeManager(adapters: [adapter])
        await manager.start()
        let latestReceived = expectation(description: "Second approval receives attention")
        let firstRestored = expectation(description: "First approval is restored")
        var sawLatest = false
        let cancellable = manager.$latestAttentionSessionID.sink { sessionID in
            if sessionID == "codex:second" {
                sawLatest = true
                latestReceived.fulfill()
            } else if sawLatest, sessionID == "codex:first" {
                firstRestored.fulfill()
            }
        }

        adapter.emit(approvalEvent(sessionID: "first", requestID: "request-1", timestamp: 1_000))
        adapter.emit(approvalEvent(sessionID: "second", requestID: "request-2", timestamp: 2_000))
        await fulfillment(of: [latestReceived], timeout: 2)
        adapter.emit(sequencedEvent(sessionID: "second", sequence: 3, kind: .approvalResolved))
        await fulfillment(of: [firstRestored], timeout: 2)

        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(manager.sessions["codex:first"]?.pendingApproval?.id, "request-1")
        XCTAssertEqual(manager.latestAttentionSessionID, "codex:first")
        await manager.stop()
    }

    func testEventFromAnotherSessionIsIgnored() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var session = AgentSession(
            id: "claude-code:session-1",
            runtime: .claudeCode,
            provider: .anthropic,
            nativeSessionID: "session-1",
            workspace: nil,
            state: .idle,
            model: nil,
            latestActivity: nil,
            pendingApproval: nil,
            pendingUserInput: nil,
            startedAt: startedAt,
            updatedAt: startedAt,
            metadata: [:]
        )
        let unrelated = AgentEvent(
            id: UUID(),
            runtime: .codex,
            provider: .openAI,
            sessionID: "session-2",
            timestamp: Date(timeIntervalSince1970: 2_000),
            kind: .error,
            title: "Failure",
            detail: nil,
            tool: nil,
            approval: nil,
            userInput: nil,
            metadata: [:]
        )

        AgentSessionReducer.reduce(&session, event: unrelated)

        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.updatedAt, startedAt)
    }

    private func event(
        kind: AgentEventKind,
        approval: AgentApprovalRequest? = nil
    ) -> AgentEvent {
        AgentEvent(
            id: UUID(),
            runtime: .codex,
            provider: .openAI,
            sessionID: "session-1",
            timestamp: Date(timeIntervalSince1970: 2_000),
            kind: kind,
            title: nil,
            detail: nil,
            tool: nil,
            approval: approval,
            userInput: nil,
            metadata: [:]
        )
    }

    func testCodexConversationParserKeepsUserAndAssistantMessagesInTurnOrder() {
        let response = JSONValue.object([
            "thread": .object([
                "turns": .array([
                    .object([
                        "startedAt": .number(2_000),
                        "items": .array([
                            .object([
                                "id": .string("user-1"),
                                "type": .string("userMessage"),
                                "content": .array([
                                    .object(["type": .string("text"), "text": .string("Inspect the project")]),
                                ]),
                            ]),
                            .object([
                                "id": .string("agent-1"),
                                "type": .string("agentMessage"),
                                "text": .string("I found the issue."),
                            ]),
                            .object([
                                "id": .string("command-1"),
                                "type": .string("commandExecution"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])

        let messages = CodexAgentRuntimeAdapter.conversationMessages(from: response)

        XCTAssertEqual(messages.map(\.id), ["user-1", "agent-1"])
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.content), ["Inspect the project", "I found the issue."])
        XCTAssertEqual(messages.first?.createdAt, Date(timeIntervalSince1970: 2_000))
    }

    func testCompactIslandOnlyAddsSmallRuntimeIndicatorWidth() {
        let size = islandSize(mode: .compact, view: .overview, nw: 184, nh: 32)

        XCTAssertEqual(size.0, 240)
        XCTAssertEqual(size.1, 32)
    }

    func testHiddenIslandIsOnlyASmallPeek() {
        let size = islandSize(mode: .hidden, view: .overview, nw: 184, nh: 32)

        XCTAssertEqual(size.0, 184)
        XCTAssertEqual(size.1, IslandConst.hiddenPeekHeight)
    }

    func testCodexSessionTitleUsesPreviewBeforeWorkspaceName() {
        let session = AgentSession(
            id: "codex:thread-title",
            runtime: .codex,
            provider: .openAI,
            nativeSessionID: "thread-title",
            workspace: URL(fileURLWithPath: "/tmp/ace"),
            state: .idle,
            model: nil,
            latestActivity: nil,
            pendingApproval: nil,
            pendingUserInput: nil,
            startedAt: Date(),
            updatedAt: Date(),
            metadata: ["preview": .string("Investigate the loading issue in the Codex chat")]
        )

        XCTAssertEqual(session.displayTitle, "Investigate the loading issue in the Codex chat")
    }

    func testCodexSessionTitleSkipsAttachmentBoilerplate() {
        let session = AgentSession(
            id: "codex:thread-attachment-title",
            runtime: .codex,
            provider: .openAI,
            nativeSessionID: "thread-attachment-title",
            workspace: URL(fileURLWithPath: "/tmp/ace"),
            state: .idle,
            model: nil,
            latestActivity: nil,
            pendingApproval: nil,
            pendingUserInput: nil,
            startedAt: Date(),
            updatedAt: Date(),
            metadata: [
                "preview": .string("# Files mentioned by the user:\nimage.png\n\n## My request:\nFix the unreadable chat field")
            ]
        )

        XCTAssertEqual(session.displayTitle, "Fix the unreadable chat field")
    }

    func testCodexTransportDecodesThreadResponsesWithMixedJSONValues() throws {
        let data = try XCTUnwrap(
            "{\"id\":7,\"result\":{\"thread\":{\"turns\":[],\"loaded\":true,\"optional\":null}}}"
                .data(using: .utf8)
        )

        let message = try XCTUnwrap(CodexAppServerTransport.decodeMessage(data))

        XCTAssertEqual(message["id"]?.numberValue, 7)
        XCTAssertEqual(message["result"]?["thread"]?["loaded"], .bool(true))
        XCTAssertEqual(message["result"]?["thread"]?["optional"], .null)
    }

    func testNotchlessScreenDoesNotBecomeAFullWidthBlackBar() {
        let width = IslandWindowController.effectiveNotchWidth(
            screenWidth: 1_920,
            safeAreaTop: 0,
            leftAuxWidth: nil,
            rightAuxWidth: nil
        )

        XCTAssertEqual(width, IslandConst.notchWidth)
    }

    private func sequencedEvent(
        sessionID: String,
        sequence: UInt64,
        kind: AgentEventKind
    ) -> AgentEvent {
        AgentEvent(
            id: UUID(),
            sequence: sequence,
            runtime: .codex,
            provider: .openAI,
            sessionID: sessionID,
            timestamp: Date(timeIntervalSince1970: Double(sequence)),
            kind: kind,
            title: nil,
            detail: nil,
            tool: nil,
            approval: nil,
            userInput: nil,
            metadata: [:]
        )
    }

    private func approvalEvent(
        sessionID: String,
        requestID: String,
        timestamp: TimeInterval
    ) -> AgentEvent {
        AgentEvent(
            id: UUID(),
            runtime: .codex,
            provider: .openAI,
            sessionID: sessionID,
            timestamp: Date(timeIntervalSince1970: timestamp),
            kind: .approvalRequested,
            title: "Approval",
            detail: nil,
            tool: nil,
            approval: AgentApprovalRequest(
                id: requestID,
                title: "Approval",
                detail: nil,
                tool: nil,
                choices: [.allow, .deny]
            ),
            userInput: nil,
            metadata: [:]
        )
    }
}

@MainActor
private final class FakeAgentRuntimeAdapter: AgentRuntimeAdapter, AgentRuntimeStatusReporting, AgentConversationRuntimeAdapter {
    let id: AgentRuntimeID = .codex
    let capabilities = AgentRuntimeCapabilities(
        observeSessions: true,
        startSession: true,
        resumeSession: true,
        interrupt: true,
        approvals: true,
        userInputRequests: true,
        toolEvents: true,
        fileChanges: true,
        commandEvents: true,
        subagents: false,
        runtimeModelSelection: true,
        runtimeReasoningSelection: true
    )
    let events: AsyncStream<AgentEvent>
    let statusUpdates: AsyncStream<RuntimeAvailability>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let statusContinuation: AsyncStream<RuntimeAvailability>.Continuation

    var resolvedSessionID: String?
    var resolvedRequestID: String?
    var resolvedDecision: ApprovalDecision?
    var inputSessionID: String?
    var inputRequestID: String?
    var inputAnswers: [String: [String]]?
    var startedRequest: StartAgentSessionRequest?
    var resumedNativeSessionID: String?
    var listedSessions: [AgentSession] = []
    var sentPrompt: String?
    var calls: [String] = []

    init() {
        let pair = AsyncStream<AgentEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        let statusPair = AsyncStream<RuntimeAvailability>.makeStream()
        statusUpdates = statusPair.stream
        statusContinuation = statusPair.continuation
    }

    func emit(_ event: AgentEvent) {
        continuation.yield(event)
    }

    func emitStatus(_ status: RuntimeAvailability) {
        statusContinuation.yield(status)
    }

    func detectAvailability() async -> RuntimeAvailability { .available(version: "test") }
    func connect() async throws {}
    func disconnect() async {}
    func listModels() async throws -> [ModelDescriptor] {
        [
            ModelDescriptor(
                id: "gpt-test",
                provider: .openAI,
                displayName: "GPT Test",
                capabilities: ModelCapabilities(
                    text: true,
                    vision: false,
                    attachments: false,
                    toolCalling: true,
                    webSearch: true,
                    reasoning: true,
                    streaming: true
                ),
                reasoningOptions: [
                    ReasoningOption(id: "high", displayName: "High", providerValue: "high"),
                ],
                contextWindow: nil,
                maxOutputTokens: nil,
                isDeprecated: false,
                metadata: ["defaultReasoningEffort": "high"]
            ),
        ]
    }
    func listSessions() async throws -> [AgentSession] { listedSessions }
    func startSession(_ request: StartAgentSessionRequest) async throws -> AgentSession {
        startedRequest = request
        let now = Date(timeIntervalSince1970: 2_000)
        return AgentSession(
            id: "codex:started-thread",
            runtime: .codex,
            provider: .openAI,
            nativeSessionID: "started-thread",
            workspace: request.workspace,
            state: .working,
            model: request.model,
            latestActivity: nil,
            pendingApproval: nil,
            pendingUserInput: nil,
            startedAt: now,
            updatedAt: now,
            metadata: [:]
        )
    }
    func resumeSession(id: String) async throws -> AgentSession {
        resumedNativeSessionID = id
        calls.append("resume:\(id)")
        let now = Date(timeIntervalSince1970: 2_001)
        return AgentSession(
            id: "codex:\(id)",
            runtime: .codex,
            provider: .openAI,
            nativeSessionID: id,
            workspace: startedRequest?.workspace,
            state: .idle,
            model: startedRequest?.model,
            latestActivity: nil,
            pendingApproval: nil,
            pendingUserInput: nil,
            startedAt: now,
            updatedAt: now,
            metadata: [:]
        )
    }
    func interrupt(sessionID: String) async throws {}
    func loadConversation(sessionID: String) async throws -> [AgentConversationMessage] { [] }
    func sendPrompt(sessionID: String, prompt: String, model: ModelSelection?) async throws {
        calls.append("send:\(sessionID)")
        sentPrompt = prompt
    }
    func resolveApproval(
        sessionID: String,
        requestID: String,
        decision: ApprovalDecision
    ) async throws {
        resolvedSessionID = sessionID
        resolvedRequestID = requestID
        resolvedDecision = decision
    }

    func respondToUserInput(
        sessionID: String,
        requestID: String,
        answers: [String: [String]]
    ) async throws {
        inputSessionID = sessionID
        inputRequestID = requestID
        inputAnswers = answers
    }
}
