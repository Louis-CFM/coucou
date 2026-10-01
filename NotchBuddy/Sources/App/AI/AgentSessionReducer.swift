import Foundation

enum AgentSessionReducer {
    static func reduce(_ session: inout AgentSession, event: AgentEvent) {
        guard event.runtime == session.runtime,
              event.sessionID == session.nativeSessionID else {
            return
        }

        if isTerminal(session.state), !canReopen(event.kind) {
            return
        }

        session.updatedAt = max(session.updatedAt, event.timestamp)

        switch event.kind {
        case .sessionStarted, .sessionResumed:
            session.state = .working
            session.pendingApproval = nil
            session.pendingUserInput = nil
        case .sessionEnded:
            session.state = .disconnected
            session.pendingApproval = nil
            session.pendingUserInput = nil
        case .userPrompt, .activityStarted, .activityUpdated,
             .toolStarted, .toolCompleted, .commandStarted,
             .commandCompleted, .fileChanged, .subagentStarted,
             .subagentCompleted:
            if session.state != .waitingForApproval && session.state != .waitingForUser {
                session.state = .working
            }
        case .activityCompleted:
            if session.state != .waitingForApproval && session.state != .waitingForUser {
                session.state = .idle
            }
        case .toolFailed, .commandFailed, .error:
            session.state = .failed
            session.pendingApproval = nil
            session.pendingUserInput = nil
        case .cancelled:
            session.state = .cancelled
            session.pendingApproval = nil
            session.pendingUserInput = nil
        case .approvalRequested:
            if session.pendingApproval?.id == event.approval?.id { break }
            session.state = .waitingForApproval
            session.pendingApproval = event.approval
            session.pendingUserInput = nil
        case .approvalResolved:
            if let resolvedID = event.metadata["requestID"]?.stringValue,
               let pendingID = session.pendingApproval?.id,
               resolvedID != pendingID {
                break
            }
            session.state = .working
            session.pendingApproval = nil
        case .userInputRequested:
            if session.pendingUserInput?.id == event.userInput?.id { break }
            session.state = .waitingForUser
            session.pendingUserInput = event.userInput
            session.pendingApproval = nil
        case .completed:
            session.state = .completed
            session.pendingApproval = nil
            session.pendingUserInput = nil
        case .rateLimited, .warning, .providerSpecific:
            break
        }

        if let title = event.title {
            if var activity = session.latestActivity,
               activity.completedAt == nil,
               event.kind == .activityCompleted {
                activity.completedAt = event.timestamp
                session.latestActivity = activity
            } else {
                session.latestActivity = AgentActivity(
                    id: event.id,
                    title: title,
                    detail: event.detail,
                    startedAt: event.timestamp,
                    completedAt: event.kind == .activityCompleted ? event.timestamp : nil
                )
            }
        }
    }

    private static func isTerminal(_ state: AgentSessionState) -> Bool {
        switch state {
        case .completed, .failed, .cancelled, .disconnected:
            true
        default:
            false
        }
    }

    private static func canReopen(_ kind: AgentEventKind) -> Bool {
        switch kind {
        case .sessionStarted, .sessionResumed, .userPrompt, .activityStarted:
            true
        default:
            false
        }
    }
}
