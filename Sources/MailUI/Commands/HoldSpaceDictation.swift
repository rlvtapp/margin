#if os(macOS)
import AppKit
import AVFoundation
import Speech
import SwiftUI

/// App-local push to talk. A short Space is still a space; secure fields are excluded.
@MainActor
final class HoldSpaceDictation {
    static let shared = HoldSpaceDictation()
    private var monitor: Any?
    private var resignObserver: Any?
    private var delay: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private weak var editor: NSTextView?
    private var insertion: LiveDictationInsertion?
    private var hasFinalResult = false
    private var session = UUID()
    private var held = false
    private var started = false
    private var transcript = ""
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var panel: DictationStatusPanel?
    /// Off until turned on in Settings → Experimental; off, Space is only ever a space.
    var isEnabled = false { didSet { if !isEnabled { cancel() } } }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { _ in
            Task { @MainActor in self.cancel() }
        }
    }

    func handle(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        if event.type == .keyDown, event.keyCode == 53, held || started {
            cancel()
            return true
        }
        guard event.keyCode == 49 else {
            if event.type == .keyDown, held || started {
                if !started { insert(" ") }
                cancel()
            }
            return false
        }
        if event.type == .keyUp {
            guard held else { return false }
            held = false
            delay?.cancel()
            if started { finish() }
            else {
                insert(" ")
                cancel()
            }
            return true
        }
        if held { return true }
        guard !event.isARepeat,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let text = event.window?.firstResponder as? NSTextView, text.isEditable,
              !(text.delegate is NSSecureTextField) else { return false }
        cancel()
        editor = text
        insertion = LiveDictationInsertion(editor: text)
        held = true
        let token = session
        delay = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, held, session == token else { return }
            started = true
            show("Preparing microphone…")
            await begin(token)
        }
        return true
    }

    private func begin(_ token: UUID) async {
        let authorized = await SpeechPermission.request()
        guard session == token, held else { return }
        guard authorized else { fail("Allow speech recognition in System Settings."); return }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard session == token, held else { return }
        guard microphone else { fail("Allow microphone access in System Settings."); return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            fail("On-device dictation isn't available for this language.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { fail("No microphone is available."); return }
        // Speech requests accept buffers from the audio render callback. The callback must
        // stay off the main actor; Speech's Objective-C type has no Sendable annotation.
        nonisolated(unsafe) let audioRequest = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in audioRequest.append(buffer) }
        self.engine = engine
        self.request = request
        do {
            engine.prepare()
            try engine.start()
        } catch { fail("Couldn't start the microphone."); return }
        show("Listening…", hint: "Let go of Space to write · Esc to cancel")
        recognition = recognizer.recognitionTask(with: request) { @Sendable result, error in
            let words = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failed = error != nil
            Task { @MainActor in
                guard self.session == token else { return }
                if let words {
                    self.transcript = words
                    guard self.insertion?.update(words) == true else { self.cancel(); return }
                }
                if final {
                    self.hasFinalResult = true
                    self.stopAudio()
                    if !self.held {
                        self.insert(self.transcript)
                        self.cancel()
                    }
                } else if failed {
                    self.fail("Dictation stopped. Try holding Space again.")
                }
            }
        }
    }

    private func finish() {
        if hasFinalResult {
            insert(transcript)
            cancel()
            return
        }
        guard request != nil else { cancel(); return }
        stopAudio()
        request?.endAudio()
        show("Finishing…")
        let token = session
        timeout = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, session == token else { return }
            insert(transcript)
            cancel()
        }
    }

    private func insert(_ words: String) {
        insertion?.commit(words)
    }

    private func stopAudio() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }

    private func cancel() {
        session = UUID()
        delay?.cancel()
        timeout?.cancel()
        stopAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        held = false
        started = false
        transcript = ""
        hasFinalResult = false
        insertion?.cancel()
        insertion = nil
        editor = nil
        panel?.orderOut(nil)
    }

    private func fail(_ message: String) {
        cancel()
        show(message, hint: "Dictation stays on this Mac")
        timeout = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }

    private func show(_ title: String, hint: String = "Esc to cancel") {
        let panel = self.panel ?? DictationStatusPanel()
        panel.show(title: title, hint: hint, on: editor?.window?.screen ?? NSScreen.main)
        self.panel = panel
    }
}
#endif
