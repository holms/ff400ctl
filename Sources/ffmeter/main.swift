import AVFoundation
import CoreAudio
import FFCore

// ffmeter — capture N seconds from the FF400's CoreAudio input and
// print per-channel level stats as one JSON line. Used by
// scripts/hardware-smoke.sh (HWTEST_LEVEL) to prove the device actually
// applied mixer/preamp changes: recording is pre-mixer, so the meters
// show what the hardware captured.
//
//   ffmeter [seconds=1.5] [channels=1,2]     (channels are 1-based)
//
// SAFETY: ASFW can intermittently stall the FireWire controller's
// interrupt delivery right after a stream STOPS ([IrqStall] in the
// driver log; recover by restarting the controller / replugging the
// adapter). Callers should keep one playback stream running across
// consecutive measurements so a test causes as few stream stops as
// possible.
//
// Errors (no device / start failure / 0 frames) go to stderr, exit 1.

func err(_ s: String) -> Never {
    FileHandle.standardError.write("ffmeter: \(s)\n".data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
let secs = args.count > 1 ? (Double(args[1]) ?? -1) : 1.5
guard secs > 0 else { err("usage: ffmeter [seconds] [channels=1,2]") }
let channels: [Int] = (args.count > 2 ? args[2] : "1,2")
    .split(separator: ",").compactMap { Int($0) }
guard !channels.isEmpty, channels.allSatisfy({ $0 >= 1 }) else {
    err("usage: ffmeter [seconds] [channels=1,2]")
}

// Find the FF400's CoreAudio device (match on the published name).
func firefaceDeviceID() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
    else { return nil }
    var ids = [AudioDeviceID](repeating: 0,
                            count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return nil }
    for id in ids {
        var n = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &n, 0, nil, &s, &name) == noErr,
           let nm = name?.takeRetainedValue() as String?,
           DevicePresence.isFireface400(name: nm) { return id }
    }
    return nil
}

guard let dev = firefaceDeviceID() else { err("no Fireface 400 audio device") }

let engine = AVAudioEngine()
var d = dev
guard AudioUnitSetProperty(engine.inputNode.audioUnit!,
                           kAudioOutputUnitProperty_CurrentDevice,
                           kAudioUnitScope_Global, 0,
                           &d, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
else { err("could not select the Fireface as input device") }

let fmt = engine.inputNode.inputFormat(forBus: 0)
let nch = Int(fmt.channelCount)
for c in channels where c > nch {
    err("channel \(c) out of range (device has \(nch))")
}

var accs = [LevelMeter.Accumulator](repeating: .init(), count: nch)
var frames = 0
let lock = NSLock()
engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
    guard let data = buf.floatChannelData else { return }
    let n = Int(buf.frameLength)
    lock.lock()
    defer { lock.unlock() }
    for c in channels {
        accs[c - 1].add(UnsafeBufferPointer(start: data[c - 1], count: n))
    }
    frames += n
}
do { try engine.start() } catch { err("capture start failed: \(error)") }
Thread.sleep(forTimeInterval: secs)
engine.stop()
lock.lock()
guard frames > 0 else { err("captured 0 frames") }

var parts: [String] = []
for c in channels {
    parts.append(String(
        format: "{\"ch\":%d,\"rms_db\":%.1f,\"peak_db\":%.1f}",
        c, accs[c - 1].rmsDB, accs[c - 1].peakDB))
}
print("{\"frames\":\(frames),\"channels\":[\(parts.joined(separator: ","))]}")
