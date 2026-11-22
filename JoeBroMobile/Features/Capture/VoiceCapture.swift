import Foundation
import AVFoundation
import Speech
import Observation

@MainActor
@Observable final class VoiceCapture {
    var isRecording = false
    var transcript = ""
    var error: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)

    func start() async {
        guard !isRecording else { return }
        let allowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
        guard allowed else { error = "Enable Speech Recognition in iPhone Settings."; return }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            error = "On-device speech recognition is unavailable for this language."; return
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard microphone else { error = "Enable Microphone access in iPhone Settings."; return }
        transcript = ""
        error = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        task = recognizer.recognitionTask(with: request) { [weak self] result, failure in
            Task { @MainActor in
                if let result { self?.transcript = result.bestTranscription.formattedString }
                // Stopping cancels the recognition task, which reports "No speech detected" (or a
                // cancellation) even when words came through. Only a failure mid-recording with
                // nothing heard is worth showing.
                if failure != nil, let self {
                    let heard = !self.transcript.trimmingCharacters(in: .whitespaces).isEmpty
                    if self.isRecording && !heard { self.error = "Didn't catch that. Try again." }
                    self.stop()
                }
            }
        }
        do { engine.prepare(); try engine.start(); isRecording = true }
        catch { self.error = error.localizedDescription; stop() }
    }

    func stop() {
        guard isRecording || request != nil else { return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
    }
}
