import Foundation

/// Coordinates tool approval requests between the MCP execution loop and the Notch / Dynamic Island UI.
@MainActor
final class MCPApprovalManager {

    static let shared = MCPApprovalManager()

    private var activeContinuation: CheckedContinuation<Bool, Never>?

    private init() {}

    /// Presents a native approval card in the Notch and waits for user's decision (Allow / Deny).
    func requestApproval(tool: MCPTool, arguments: [String: AnyCodable]) async -> Bool {
        // If an approval is already waiting, cancel it safely
        activeContinuation?.resume(returning: false)
        activeContinuation = nil

        return await withCheckedContinuation { continuation in
            self.activeContinuation = continuation

            let formattedArgs = arguments.map { "\($0.key): \($0.value.rawValue)" }.joined(separator: ", ")
            let displayCommand = "\(tool.serverName) → \(tool.name)(\(formattedArgs))"

            let info = ApprovalInfo(
                sessionId: "mcp_tool_execution",
                tool: "MCP: \(tool.name)",
                command: displayCommand,
                inputKey: tool.id,
                pillId: "mcp_tool"
            )

            let state = AppState.shared
            state.pendingApproval = info
            state.stateOverride = .approval
            state.view = .approval

            SoundEngine.shared.play("approval")
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.approval)
        }
    }

    /// Resolves the pending approval when user clicks "Allow" or "Deny" in the Notch.
    func handleDecision(isAllowed: Bool) {
        guard let continuation = activeContinuation else { return }
        activeContinuation = nil

        let state = AppState.shared
        state.pendingApproval = nil
        state.stateOverride = nil
        state.view = .prompt

        continuation.resume(returning: isAllowed)
    }

    /// Cancels any pending approval if the Island closes or resets.
    func cancelPending() {
        guard let continuation = activeContinuation else { return }
        activeContinuation = nil
        continuation.resume(returning: false)
    }
}
