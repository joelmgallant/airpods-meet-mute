import AVFAudio
import AVFoundation
import Foundation

/// Receives the AirPods mute gesture and mirrors Meet's state into the system mute state.
final class GestureListener {
    private let audioApplication = AVAudioApplication.shared
    private var heldEngine: AVAudioEngine?

    /// Called on the main thread with the requested mute state; returns true if handled.
    var onMuteRequest: ((Bool) -> Bool)?

    func start() throws {
        try audioApplication.setInputMuteStateChangeHandler { [weak self] inputShouldBeMuted in
            guard let self else { return false }
            return Self.onMain { self.onMuteRequest?(inputShouldBeMuted) ?? false }
        }
    }

    /// Keeps the system mute state equal to Meet's, so the next gesture requests the right toggle.
    func syncSystemMute(_ muted: Bool) {
        guard audioApplication.isInputMuted != muted else { return }
        do {
            try audioApplication.setInputMuted(muted)
        } catch {
            NSLog("AirPodsMeetMute: setInputMuted(\(muted)) failed: \(error)")
        }
    }

    /// Holds a silent microphone input so macOS delivers the gesture to us (per the spike).
    /// Returns an error message when the tap could not start. If a previously held engine has
    /// stopped (device change, AirPods reconnect), it is torn down and rebuilt.
    @discardableResult
    func setHoldingInput(_ hold: Bool) -> String? {
        if hold, let engine = heldEngine, !engine.isRunning {
            releaseHeldEngine()
        }
        if hold, heldEngine == nil {
            return startHeldEngine()
        }
        if !hold {
            releaseHeldEngine()
        }
        return nil
    }

    private func startHeldEngine() -> String? {
        guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else {
            return "Microphone access denied — enable it in System Settings › Privacy & Security › Microphone"
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        // installTap raises an uncatchable NSException on a zero-rate format (no usable input device).
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            return "No usable microphone input — check the input device in System Settings › Sound"
        }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { _, _ in }
        do {
            try engine.start()
            heldEngine = engine
            return nil
        } catch {
            inputNode.removeTap(onBus: 0)
            return "Could not hold microphone input: \(error.localizedDescription)"
        }
    }

    private func releaseHeldEngine() {
        guard let engine = heldEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        heldEngine = nil
    }

    private static func onMain<Value>(_ work: () -> Value) -> Value {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}
