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

    func toggle(into text: @escaping @MainActor @Sendable (String) -> Void) {
        isListening ? stop() : start(into: text)
    }

    func start(into text: @escaping @MainActor @Sendable (String) -> Void) {
        problem = nil
        Task { @MainActor in
            guard await SpeechPermission.request() else {
                self.problem = String(localized: "Allow speech recognition for Margin in System Settings to dictate.")
                return
            }
            self.begin(into: text)
        }
    }

    private func begin(into text: @escaping @MainActor @Sendable (String) -> Void) {
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
        // Speech requests accept buffers from the audio render callback. The callback must
        // stay off the main actor; Speech's Objective-C type has no Sendable annotation.
        nonisolated(unsafe) let audioRequest = request
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in audioRequest.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            problem = error.localizedDescription
            return
        }
        self.engine = engine
        isListening = true
        task = recognizer.recognitionTask(with: request) { @Sendable result, error in
            let words = result?.bestTranscription.formattedString
            let finished = error != nil || result?.isFinal == true
            Task { @MainActor in
                if let words { text(words) }
                if finished { self.stop() }
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
        case .claudeCode:
            return CommandLineTool.claude.modelChoices
        default:
            return []
        }
    }

    /// Every ready assistant with the models it offers, quickest first, for Ask's picker.
    func askChoices() async -> [(settings: AssistantSettings, models: [ModelChoice])] {
        var result: [(settings: AssistantSettings, models: [ModelChoice])] = []
        for settings in AssistantProvider.allCases.compactMap({ assistantProfiles[$0] }) where isReady(settings) {
            result.append((settings, await modelChoices(for: settings)))
        }
        return result
    }

    /// The models an assistant offers: its own list for Claude Code and ChatGPT, the provider's
    /// for a key or a server (quick ones first), none for Apple's model.
    func modelChoices(for settings: AssistantSettings) async -> [ModelChoice] {
        let key = savedAPIKey(for: settings.provider)
        switch settings.provider {
        case .claudeCode, .codex:
            return AssistantSettingsView.knownModels(settings.provider)
        case .claude:
            guard let key else { return [] }
            return AssistantSettingsView.quickestFirst((try? await AnthropicModel.availableModels(apiKey: key)) ?? [settings.model])
        case .chatGPT, .gemini, .grok, .ollama, .lmStudio, .custom:
            guard let url = URL(string: settings.baseURL) else { return [] }
            return AssistantSettingsView.quickestFirst((try? await OpenAICompatibleModel.availableModels(baseURL: url, apiKey: key)) ?? [settings.model])
        default:
            return []
        }
    }

    /// Makes an added assistant answer Ask and write, with `model` when given.
    public func useAssistant(_ provider: AssistantProvider, model name: String?) {
        var settings = assistantProfiles[provider] ?? AssistantSettings(provider: provider)
        if let name { settings.model = name }
        applyAssistant(settings, apiKey: nil)
    }

    /// Switches to another model of the same provider.
    public func useModel(_ name: String) {
        var settings = assistantSettings
        settings.model = name
        applyAssistant(settings, apiKey: nil)
    }
}
