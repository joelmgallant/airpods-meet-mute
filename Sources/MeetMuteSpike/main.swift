import AppKit
import AVFAudio
import AVFoundation

// Throwaway spike: does macOS deliver the AirPods mute gesture to this app?
// Mode "tap" (pass `--args tap` to `open`) also holds a silent microphone input.

let holdInput = CommandLine.arguments.contains("tap")
let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/MeetMuteSpike.log")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

log("spike start mode=\(holdInput ? "handler+tap" : "handler-only") pid=\(ProcessInfo.processInfo.processIdentifier)")

let audioApplication = AVAudioApplication.shared
do {
    try audioApplication.setInputMuteStateChangeHandler { inputShouldBeMuted in
        log("GESTURE inputShouldBeMuted=\(inputShouldBeMuted) thread=\(Thread.isMainThread ? "main" : "background")")
        return true
    }
    log("handler registered isInputMuted=\(audioApplication.isInputMuted)")
} catch {
    log("handler registration FAILED: \(error)")
}

NotificationCenter.default.addObserver(
    forName: AVAudioApplication.inputMuteStateChangeNotification,
    object: nil,
    queue: .main
) { notification in
    log("NOTIFICATION inputMuteStateChange userInfo=\(notification.userInfo ?? [:])")
}

var heldEngine: AVAudioEngine?
if holdInput {
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async {
            log("microphone access granted=\(granted)")
            guard granted else { return }
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
            do {
                try engine.start()
                heldEngine = engine
                log("input tap running format=\(format)")
            } catch {
                log("engine start FAILED: \(error)")
            }
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.run()
