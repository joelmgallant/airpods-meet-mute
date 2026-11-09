import AVFAudio
import AVFoundation
import Foundation

/// Receives the AirPods mute gesture and mirrors Meet's state into the system mute state.
final class GestureListener {
    private let audioApplication = AVAudioApplication.shared
    private var heldEngine: AVAudioEngine?

    /// Called on the main thread with the requested mute state; returns true if handled.
    var onMuteRequest: ((Bool) -> Bool)?

    /// Observing this notification is what opts the app into AirPods muting on macOS: without
    /// it the server logs "no recording audio apps found that are opted in to input muting"
    /// and rejects every press (found by bisecting against the spike, 2026-11-09).
    private var muteStateObserver: NSObjectProtocol?

    /// True while syncSystemMute is inside setInputMuted. setInputMuted invokes our own mute
    /// handler synchronously ("top-down mute"); the handler must accept that without driving
    /// Meet or calling setInputMuted again, which re-enters libdispatch and crashes.
    private var isSyncingSystemMute = false

    func start() throws {
        try audioApplication.setInputMuteStateChangeHandler { [weak self] inputShouldBeMuted in
            guard let self else { return false }
            return Self.onMain {
                if self.isSyncingSystemMute { return true }
                return self.onMuteRequest?(inputShouldBeMuted) ?? false
            }
        }
        muteStateObserver = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification,
            object: nil,
            queue: .main
        ) { _ in }
    }

    /// Keeps the system mute state equal to Meet's, so the next gesture requests the right toggle.
    /// Main thread only. Never call from inside the mute handler: returning true from the
    /// handler already makes the system record the requested state.
    /// Returns an error message when the system state could not be updated, nil otherwise.
    @discardableResult
    func syncSystemMute(_ muted: Bool) -> String? {
        guard audioApplication.isInputMuted != muted else { return nil }
        isSyncingSystemMute = true
        defer { isSyncingSystemMute = false }
        do {
            try audioApplication.setInputMuted(muted)
            return nil
        } catch {
            NSLog("AirPodsMeetMute: setInputMuted(\(muted)) failed: \(error)")
            return "Could not update the system mute state: \(error.localizedDescription)"
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
