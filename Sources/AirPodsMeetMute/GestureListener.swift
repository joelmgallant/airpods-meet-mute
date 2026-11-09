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
    /// Returns an error message when the tap could not start.
    @discardableResult
    func setHoldingInput(_ hold: Bool) -> String? {
        if hold, heldEngine == nil {
            guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else {
                return "Microphone access denied — enable it in System Settings › Privacy & Security › Microphone"
            }
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNode.outputFormat(forBus: 0)) { _, _ in }
            do {
                try engine.start()
                heldEngine = engine
            } catch {
                inputNode.removeTap(onBus: 0)
                return "Could not hold microphone input: \(error.localizedDescription)"
            }
        } else if !hold, let engine = heldEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            heldEngine = nil
        }
        return nil
    }

    private static func onMain<Value>(_ work: () -> Value) -> Value {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}
