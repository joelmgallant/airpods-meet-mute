// Standalone CoreAudio probe for the system-wide mute spike.
// Usage: swift scripts/system-mute-probe.swift status|list|mute|unmute|level
import AVFoundation
import AppKit
import CoreAudio

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var propertyAddress = address(selector)
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, &unmanaged) == noErr else { return "?" }
    return (unmanaged?.takeRetainedValue() as String?) ?? "?"
}

func readUInt32(_ object: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress) -> UInt32? {
    var propertyAddress = propertyAddress
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, &value) == noErr ? value : nil
}

func settable(_ object: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress) -> Bool {
    var propertyAddress = propertyAddress
    guard AudioObjectHasProperty(object, &propertyAddress) else { return false }
    var isSettable = DarwinBoolean(false)
    return AudioObjectIsPropertySettable(object, &propertyAddress, &isSettable) == noErr && isSettable.boolValue
}

func defaultInput() -> AudioObjectID {
    var propertyAddress = address(kAudioHardwarePropertyDefaultInputDevice)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(systemObject, &propertyAddress, 0, nil, &size, &device)
    return device
}

let muteAddress = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)

func status() {
    let device = defaultInput()
    print("default input: \(readString(device, kAudioObjectPropertyName)) uid=\(readString(device, kAudioDevicePropertyDeviceUID))")
    print("  input mute settable=\(settable(device, muteAddress)) value=\(readUInt32(device, muteAddress).map(String.init) ?? "n/a")")
    for element in [kAudioObjectPropertyElementMain] + (1...4).map({ AudioObjectPropertyElement($0) }) {
        var volumeAddress = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, element)
        guard settable(device, volumeAddress) else { continue }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume)
        print("  input volume element \(element) settable=true value=\(volume)")
    }
}

func list() {
    guard #available(macOS 14.2, *) else { print("needs macOS 14.2"); return }
    var listAddress = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(systemObject, &listAddress, 0, nil, &size)
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(systemObject, &listAddress, 0, nil, &size, &processes)
    var found = 0
    for process in processes where readUInt32(process, address(kAudioProcessPropertyIsRunningInput)) == 1 {
        let pid = Int32(bitPattern: readUInt32(process, address(kAudioProcessPropertyPID)) ?? 0)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        print("recording: pid=\(pid) bundle=\(readString(process, kAudioProcessPropertyBundleID)) name=\(name)")
        found += 1
    }
    print("\(found) recording process(es); probe pid=\(ProcessInfo.processInfo.processIdentifier)")
}

func setMute(_ muted: Bool) {
    let device = defaultInput()
    var propertyAddress = muteAddress
    var value: UInt32 = muted ? 1 : 0
    let result = AudioObjectSetPropertyData(device, &propertyAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    print("set input mute=\(muted) on \(readString(device, kAudioObjectPropertyName)): status=\(result) now=\(readUInt32(device, muteAddress).map(String.init) ?? "n/a")")
}

func level() {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    var peak: Float = 0
    var sumSquares: Double = 0
    var samples = 0
    input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
        guard let channel = buffer.floatChannelData?[0] else { return }
        for index in 0..<Int(buffer.frameLength) {
            let sample = channel[index]
            peak = max(peak, abs(sample))
            sumSquares += Double(sample * sample)
        }
        samples += Int(buffer.frameLength)
    }
    do { try engine.start() } catch { print("engine start failed: \(error)"); return }
    print("recording from \(readString(defaultInput(), kAudioObjectPropertyName)) — talk now")
    RunLoop.main.run(until: Date().addingTimeInterval(TimeInterval(CommandLine.arguments.dropFirst(2).first.flatMap(Double.init) ?? 3)))
    engine.stop()
    let rms = samples > 0 ? sqrt(sumSquares / Double(samples)) : 0
    print(String(format: "samples=%d peak=%.5f rms=%.6f (%.1f dBFS)", samples, peak, rms, 20 * log10(max(rms, 1e-9))))
}

switch CommandLine.arguments.dropFirst().first {
case "status": status()
case "list": list()
case "mute": setMute(true)
case "unmute": setMute(false)
case "level": level()
default: print("usage: swift scripts/system-mute-probe.swift status|list|mute|unmute|level")
}
