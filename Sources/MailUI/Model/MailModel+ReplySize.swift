import Foundation

/// The reply can be written bigger: it fills the reading pane, in the same place, with the
/// conversation above it to scroll back to. The button or Esc brings it back to its usual size.
extension MailModel {
    public func toggleReplyExpanded() {
        isReplyExpanded = reply != nil && !isReplyExpanded
    }

    /// Esc in the reply: a bigger reply goes back to its usual size first; after that Esc
    /// closes it, kept in Drafts.
    func escapeReply(_ state: ComposeState) {
        if isReplyExpanded {
            isReplyExpanded = false
        } else {
            closeComposer(state, isReply: true)
        }
    }
}
