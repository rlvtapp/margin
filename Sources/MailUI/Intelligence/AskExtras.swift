import AVFoundation
import Foundation
import MailCore
import Speech
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif

/// A file added to an Ask question: its text goes along with the question.
public struct AskAttachment: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var text: String

    /// Reads a picture (the words in it) or a PDF or text file. Nil when nothing can be read.
    public static func read(_ url: URL) async -> AskAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        var text: String?
        if ext == "pdf" {
            #if canImport(PDFKit)
            text = PDFDocument(url: url)?.string
            #endif
        } else if ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"].contains(ext) {
            text = await recognizeText(url)
        } else {
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return AskAttachment(name: name, text: String(text.prefix(20_000)))
    }

    /// The words in a picture, read on this device.
    static func recognizeText(_ url: URL) async -> String? {
        #if canImport(Vision)
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            do { try VNImageRequestHandler(url: url).perform([request]) } catch { continuation.resume(returning: nil) }
        }
        #else
        return nil
        #endif
    }

    /// How attachments are added to the question the assistant sees.
    static func prompt(_ question: String, with files: [AskAttachment]) -> String {
        guard !files.isEmpty else { return question }
        return question + "\n\nFiles I attached:\n" + files.map { "--- \($0.name) ---\n\($0.text)" }.joined(separator: "\n\n")
    }
}

/// Speaking a question to Ask. Listens only while on, on this device when it can.
@MainActor @Observable
final class Dictation {
    private(set) var isListening = false
    private(set) var problem: String?
    private var engine: AVAudioEngine?
    private var task: SFSpeechRecognitionTask?

    func toggle(into text: @escaping (String) -> Void) {
        isListening ? stop() : start(into: text)
    }

    func start(into text: @escaping (String) -> Void) {
        problem = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.problem = String(localized: "Allow speech recognition for Margin in System Settings to dictate.")
                    return
                }
                self.begin(into: text)
            }
        }
    }

    private func begin(into text: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            problem = String(localized: "Dictation isn't available right now.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let engine = AVAudioEngine()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            problem = error.localizedDescription
            return
        }
        self.engine = engine
        isListening = true
        task = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                if let result { text(result.bestTranscription.formattedString) }
                if error != nil || result?.isFinal == true { self.stop() }
            }
        }
    }

    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        task?.finish()
        task = nil
        isListening = false
    }
}

extension MailModel {
    /// Models the chosen provider offers, for the picker in Ask.
    public func availableModels() async -> [String] {
        let settings = assistantSettings
        let key = savedAPIKey(for: settings.provider)
        switch settings.provider {
        case .claude:
            guard let key else { return [] }
            return (try? await AnthropicModel.availableModels(apiKey: key)) ?? []
        case .chatGPT, .gemini, .grok, .ollama, .lmStudio, .custom:
            guard let url = URL(string: settings.baseURL) else { return [] }
            return (try? await OpenAICompatibleModel.availableModels(baseURL: url, apiKey: key)) ?? []
        default:
            return []
        }
    }

    /// Switches to another model of the same provider.
    public func useModel(_ name: String) {
        var settings = assistantSettings
        settings.model = name
        applyAssistant(settings, apiKey: nil)
    }
}
