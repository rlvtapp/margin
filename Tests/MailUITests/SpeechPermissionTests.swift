import Dispatch
import Speech
import Testing
@testable import MailUI

@MainActor @Suite struct SpeechPermissionTests {
    @Test func permissionCanReplyFromABackgroundQueue() async {
        let allowed = await SpeechPermission.request { reply in
            DispatchQueue.global().async { reply(.authorized) }
        }
        #expect(allowed)
    }

    @Test func deniedPermissionCanReplyFromABackgroundQueue() async {
        let allowed = await SpeechPermission.request { reply in
            DispatchQueue.global().async { reply(.denied) }
        }
        #expect(!allowed)
    }
}
