import ActivityKit

// The Live Activity's type, shared by the app (tokens) and the widget
// extension (the views). Started and updated only from the Mac, through the
// relay: the iPhone never starts one itself.

struct MochiActivityAttributes: ActivityAttributes {
    typealias ContentState = MochiActivityState
}
