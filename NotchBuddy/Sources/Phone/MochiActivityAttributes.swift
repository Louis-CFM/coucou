import ActivityKit

// The Live Activity's type, shared by the app (tokens) and the widget
// extension (the views). Started and ended only from the Mac, through the
// relay: the iPhone never starts one itself. The iPhone also updates the
// running one when it is awake (LiveActivityLink.sessionsChanged).

struct MochiActivityAttributes: ActivityAttributes {
    typealias ContentState = MochiActivityState
}
