import Speech

/// Speech permission replies arrive on a system queue, even when requested from the UI.
/// Keep that callback explicitly Sendable so it cannot inherit main-actor isolation.
enum SpeechPermission {
    nonisolated static func request(
        using authorize: @Sendable (@escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = { reply in
            SFSpeechRecognizer.requestAuthorization(reply)
        }
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            authorize { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
