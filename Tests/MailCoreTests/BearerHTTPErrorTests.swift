import Foundation
import Testing
@testable import MailCore

struct BearerHTTPErrorTests {
    let http = BearerHTTP(token: "t") { _ in throw MailError.missingCredentials }

    func check(_ json: String) -> MailError? {
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        do { try http.check(Data(json.utf8), response, forbidden: "Forbidden."); return nil } catch { return error as? MailError }
    }

    @Test func disabledAPIIsNotASignInProblem() {
        let error = check(#"{"error":{"code":403,"message":"Calendar API has not been used","errors":[{"reason":"accessNotConfigured"}],"details":[{"@type":"x","reason":"SERVICE_DISABLED"}]}}"#)
        guard case .serverRejected(let message) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(message == "Calendar API has not been used")
    }

    @Test func missingPermissionAsksToTickEveryBox() {
        let error = check(#"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","errors":[{"reason":"insufficientPermissions"}],"details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#)
        guard case .authenticationFailed = error else { Issue.record("got \(String(describing: error))"); return }
    }

    @Test func otherRefusalKeepsWhatTheServerSaid() {
        let error = check(#"{"error":{"code":"ErrorAccessDenied","message":"Access is denied."}}"#)
        guard case .authenticationFailed(let message) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(message == "Forbidden. (Access is denied.)")
    }
}
