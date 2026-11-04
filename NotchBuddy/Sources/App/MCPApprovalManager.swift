import Foundation

/// Coordinates tool approval requests between the MCP execution loop and the Notch / Dynamic Island UI.
/// Ensures requests respect request identity (UUID) and 115s safety watchdog, preventing clobbering.
@MainActor
final class MCPApprovalManager {

    static let shared = MCPApprovalManager()

    private struct PendingEntry {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var currentPending: PendingEntry?

    private init() {}

    /// Presents a native approval card in the Notch and waits for user's decision (Allow / Deny).
    func requestApproval(tool: MCPTool, arguments: [String: AnyCodable]) async -> Bool {
        // If an approval is already waiting, cancel it safely before queueing the new one
        if let existing = currentPending {
            currentPending = nil
            existing.continuation.resume(returning: false)
        }

        let requestID = UUID()

        return await withCheckedContinuation { continuation in
            self.currentPending = PendingEntry(id: requestID, continuation: continuation)

            let formattedArgs = arguments.map { "\($0.key): \($0.value.rawValue)" }.joined(separator: ", ")
            let displayCommand = "\(tool.serverName) → \(tool.name)(\(formattedArgs))"

            let info = ApprovalInfo(
                sessionId: "mcp_tool_execution",
                tool: "MCP: \(tool.name)",
                command: displayCommand,
                inputKey: tool.id,
                pillId: "mcp_tool",
                id: requestID,
                queueCount: 1,
                projectName: tool.serverName
            )

            let state = AppState.shared
            state.pendingApproval = info
            state.stateOverride = .approval
            state.view = .approval

            SoundEngine.shared.play("approval")
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.approval)

            // 115s Safety watchdog timeout — fail closed if unanswered
            DispatchQueue.main.asyncAfter(deadline: .now() + 115) { [weak self] in
                guard let self = self, let active = self.currentPending, active.id == requestID else { return }
                self.handleDecision(isAllowed: false, for: requestID)
            }
        }
    }

    /// Resolves the pending approval when user clicks "Allow" or "Deny" in the Notch,
    /// strictly checking that the resolved ID matches the displayed card.
    func handleDecision(isAllowed: Bool, for id: UUID? = nil) {
        guard let active = currentPending else { return }
        if let id = id, id != active.id {
            // Decision arrived for a request no longer active
            return
        }
        currentPending = nil

        let state = AppState.shared
        state.pendingApproval = nil
        state.stateOverride = nil
        state.view = .prompt

        active.continuation.resume(returning: isAllowed)
    }

    /// Cancels any pending approval if the Island closes or resets.
    func cancelPending() {
        guard let active = currentPending else { return }
        currentPending = nil
        active.continuation.resume(returning: false)
    }
}
