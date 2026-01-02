import Foundation
import Speech
import AVFoundation
import os

/// Manages voice input using Apple's Speech framework
@MainActor
class VoiceInputManager: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ghostty",
        category: "voice_input"
    )
    @Published var isListening: Bool = false
    @Published var transcribedText: String = ""
    @Published var errorMessage: String?
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var silenceTimer: Timer?
    private var debounceTask: Task<Void, Never>?

    // Speech recognition error codes
    // Reference: https://developer.apple.com/documentation/speech/sfspeechrecognitionerror/code
    private let speechRecognitionCancelledErrorCode = 216 // kSFSpeechRecognitionErrorCancelled

    // Listening timeout: 60 seconds of silence stops recording
    private let silenceTimeoutSeconds: TimeInterval = 60.0

    // Debounce delay for partial results (ms) - reduces excessive UI updates
    private let partialResultsDebounceMs: UInt64 = 300_000_000 // 300ms

    // Helper wrapper for main-thread cleanup scheduled from `deinit`.
    private struct UncheckedSendable<T>: @unchecked Sendable {
        let value: T
    }

    init() {
        // Use system locale with fallback to en-US
        // TODO: Make this configurable in settings for internationalization
        let locale = Locale.current.identifier
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))

        if speechRecognizer == nil {
            // System locale not supported, try en-US fallback
            print("VoiceInputManager: Speech recognizer initialization failed for locale '\(locale)'. Your device may not support speech recognition for this locale.")

            // Try fallback to en-US
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

            // Check if fallback also failed
            if speechRecognizer == nil {
                // Neither system locale nor en-US works - speech recognition is unavailable
                print("VoiceInputManager: Fallback to en-US also failed. Speech recognition is not available on this device.")
                errorMessage = "Speech recognition is not available on this device. Please ensure your Mac supports speech recognition and try again."
            } else {
                // Fallback succeeded
                errorMessage = "Speech recognition is not available for your locale. Using English (US) as fallback."
            }
        }
        checkAuthorizationStatus()
    }

    /// Clean up resources when deallocated
    /// Critical for preventing resource leaks with AVAudioEngine
    deinit {
        debounceTask?.cancel()
        recognitionTask?.cancel()

        let timer = UncheckedSendable(value: silenceTimer)
        let engine = UncheckedSendable(value: audioEngine)
        let request = UncheckedSendable(value: recognitionRequest)

        let cleanup = {
            timer.value?.invalidate()
            request.value?.endAudio()

            engine.value?.stop()
            engine.value?.inputNode.removeTap(onBus: 0)
        }

        if Thread.isMainThread {
            cleanup()
        } else {
            DispatchQueue.main.async(execute: cleanup)
        }
    }

    /// Check current authorization status
    func checkAuthorizationStatus() {
        authorizationStatus = SFSpeechRecognizer.authorizationStatus()
    }

    /// Request authorization for speech recognition
    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.authorizationStatus = status
                if status != .authorized {
                    self?.errorMessage = self?.authorizationMessage(for: status)
                }
            }
        }
    }

    /// Start listening for speech input
    func startListening() {
        guard !isListening else { return }

        // Check authorization
        guard authorizationStatus == .authorized else {
            if authorizationStatus == .notDetermined {
                requestAuthorization()
            } else {
                errorMessage = authorizationMessage(for: authorizationStatus)
            }
            return
        }

        // Check speech recognizer availability
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Speech recognition is not available on this device"
            return
        }

        do {
            try startRecognition()
        } catch {
            errorMessage = "Failed to start speech recognition: \(error.localizedDescription)"
        }
    }

    /// Stop listening and finalize transcription
    func stopListening() {
        guard isListening else { return }

        // Invalidate silence timer
        silenceTimer?.invalidate()
        silenceTimer = nil

        // Cancel debounce task and clear reference
        debounceTask?.cancel()
        debounceTask = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest?.endAudio()

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        isListening = false
    }

    /// Toggle listening state
    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    // MARK: - Private Methods

    private func startRecognition() throws {
        // Cancel any previous task
        recognitionTask?.cancel()
        recognitionTask = nil

        // Ensure any stale engine/taps are cleared before creating a new one
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
        }

        // Note: AVAudioSession is iOS-only. On macOS, AVAudioEngine handles
        // audio routing automatically without session configuration.

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw VoiceInputError.recognitionRequestFailed
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation

        // Create audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw VoiceInputError.audioEngineFailed
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Validate format
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw VoiceInputError.invalidAudioFormat
        }

        // Buffer size: 1024 samples (~21ms at 48kHz) balances latency vs CPU overhead
        // Apple recommends 1024-4096 for speech recognition
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isListening = true
        transcribedText = ""
        errorMessage = nil

        // Set up silence timeout - auto-stop after N seconds of no speech
        // Use @MainActor to ensure timer is created on main thread
        scheduleSilenceTimer()

        // Start recognition task with debouncing for partial results
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }

                if let result = result {
                    // Reset silence timer when we get speech results
                    self.scheduleSilenceTimer()

                    // Debounce partial results to reduce excessive UI updates
                    self.debounceTask?.cancel()
                    self.debounceTask = Task {
                        try? await Task.sleep(nanoseconds: self.partialResultsDebounceMs)
                        if !Task.isCancelled {
                            self.transcribedText = result.bestTranscription.formattedString
                        }
                    }
                }

                if let error = error {
                    let nsError = error as NSError
                    let errorCode = nsError.code
                    let errorDomain = nsError.domain

                    // AFAssistant error domain (private API, use string literal)
                    let afAssistantErrorDomain = "com.apple.AFAssistant"

                    if errorCode == self.speechRecognitionCancelledErrorCode {
                        // User intentionally cancelled - this is fine, no error needed
                        Self.logger.info("Voice input cancelled by user")
                    } else if errorDomain == afAssistantErrorDomain && errorCode >= 200 && errorCode < 300 {
                        // Speech recognition-specific errors
                        let errorDetails = [
                            203: "Speech recognition is disabled due to Apple Intelligence not being enabled on macOS Sequoia or later.",
                            204: "No valid speech recognition assets found on device.",
                            209: "Unable to contact speech recognition server (offline or server unavailable).",
                        ]

                        let detail = errorDetails[errorCode] ?? error.localizedDescription
                        Self.logger.error("Voice input speech error: code=\(errorCode), domain=\(errorDomain), detail=\(detail)")
                        self.errorMessage = "Speech recognition error [\(errorCode)]: \(detail)"
                    } else {
                        // Other errors (network, audio, etc.)
                        Self.logger.error("Voice input error: code=\(errorCode), domain=\(errorDomain), description=\(error.localizedDescription)")
                        self.errorMessage = "An unexpected error occurred [\(errorCode)]: \(error.localizedDescription)"
                    }
                    self.stopListening()
                }

                if result?.isFinal == true {
                    self.stopListening()
                }
            }
        }
    }

    /// Schedule or reschedule the silence timeout timer
    /// This ensures the timer is created on @MainActor for thread safety
    @MainActor
    private func scheduleSilenceTimer() {
        // Invalidate any existing timer first
        silenceTimer?.invalidate()

        // Create new timer with proper cleanup
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeoutSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stopListening()
                self?.errorMessage = "Listening timed out due to silence. Tap mic to try again."
            }
        }
    }

    private func authorizationMessage(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "Speech recognition permission not yet requested"
        case .denied:
            return "Speech recognition permission denied. Enable it in System Settings > Privacy & Security > Speech Recognition"
        case .restricted:
            return "Speech recognition is restricted on this device"
        case .authorized:
            return ""
        @unknown default:
            return "Unknown authorization status"
        }
    }
}

// MARK: - Errors

enum VoiceInputError: LocalizedError {
    case recognitionRequestFailed
    case audioEngineFailed
    case invalidAudioFormat

    var errorDescription: String? {
        switch self {
        case .recognitionRequestFailed:
            return "Failed to create speech recognition request"
        case .audioEngineFailed:
            return "Failed to initialize audio engine"
        case .invalidAudioFormat:
            return "Invalid audio format from microphone"
        }
    }
}
