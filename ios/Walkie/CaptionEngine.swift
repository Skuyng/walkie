import AVFoundation
import Speech

/// On-device captions for incoming PCM16. Capture, the waveform, and playback stay untouched.
@MainActor
final class CaptionEngine {
    var onTranscript: (@MainActor (String) -> Void)?

    private var localeID = "nb-NO"
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var enabled = false
    private var authorized = false

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on { stop() }
    }

    func setLocale(_ identifier: String) {
        guard identifier != localeID else { return }
        localeID = identifier
        stop()
        recognizer = nil
    }

    /// Prompts only while the system status is still undecided.
    func requestAuthorizationIfNeeded() {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] newStatus in
                let ok = newStatus == .authorized
                Task { @MainActor in
                    self?.authorized = ok
                }
            }
            return
        }
        authorized = status == .authorized
    }

    func endUtterance() {
        request?.endAudio()
        request = nil
    }

    func stop() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
    }

    func append(_ data: Data) {
        guard enabled, authorized, !data.isEmpty else { return }
        guard let recognizer = preparedRecognizer(), recognizer.isAvailable else { return }
        let request = preparedRequest(recognizer)
        guard let buffer = Self.buffer(from: data) else { return }
        request.append(buffer)
    }

    private func preparedRecognizer() -> SFSpeechRecognizer? {
        if let recognizer { return recognizer }
        let created = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        recognizer = created
        return created
    }

    private func preparedRequest(_ recognizer: SFSpeechRecognizer) -> SFSpeechAudioBufferRecognitionRequest {
        if let request { return request }
        let created = SFSpeechAudioBufferRecognitionRequest()
        created.shouldReportPartialResults = true
        created.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            created.requiresOnDeviceRecognition = true
        }
        request = created
        task = recognizer.recognitionTask(with: created) { [weak self] result, error in
            let line = result?.bestTranscription.formattedString ?? ""
            let failed = error != nil && line.isEmpty
            Task { @MainActor in
                guard let self else { return }
                if !line.isEmpty {
                    self.onTranscript?(line)
                }
                if failed {
                    self.request = nil
                    self.task = nil
                }
            }
        }
        return created
    }

    /// Float32 mono at the wire rate. That is the buffer layout appended recognition accepts.
    private static func buffer(from data: Data) -> AVAudioPCMBuffer? {
        let samples = PCM16.decode(data)
        guard !samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: PCM16.sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        for index in samples.indices {
            channel[index] = samples[index]
        }
        return buffer
    }
}
