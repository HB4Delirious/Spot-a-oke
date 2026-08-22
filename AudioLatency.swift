import Foundation
import CoreAudio

/// Reads how far behind the current output device actually is.
///
/// Spotify reports where the playhead is, but that is not what has reached your
/// ears yet: the audio still has to cross the device buffer, and over Bluetooth
/// that is 150–200 ms. The handoff notes call this out as latency "the app can't
/// see" — but CoreAudio does publish it, so it can be compensated automatically
/// instead of being dialled in by hand.
///
/// This covers the *device*. It cannot know that a particular LRC file was
/// mastered against a different release — nothing can, without hearing the audio.
enum AudioLatency {

    /// Total output latency in seconds, or 0 if it can't be determined.
    static func currentSeconds() -> Double {
        guard let device = defaultOutputDevice() else { return 0 }
        let sampleRate = nominalSampleRate(device)
        guard sampleRate > 0 else { return 0 }

        let frames = frameCount(device, kAudioDevicePropertyLatency)
            + frameCount(device, kAudioDevicePropertySafetyOffset)
            + streamLatencyFrames(device)

        let seconds = Double(frames) / sampleRate
        // Anything beyond a second is a misread, not a real output path.
        return (seconds.isFinite && seconds > 0 && seconds < 1.0) ? seconds : 0
    }

    // MARK: - CoreAudio plumbing

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)

        return (status == noErr && device != kAudioObjectUnknown) ? device : nil
    }

    private static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else {
            return 0
        }
        return Double(rate)
    }

    private static func frameCount(_ device: AudioDeviceID,
                                   _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)

        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    /// The stream carries its own latency on top of the device's.
    private static func streamLatencyFrames(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)

        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return 0 }

        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr,
              let stream = streams.first else { return 0 }

        var latencyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyLatency,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var value = UInt32(0)
        var valueSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(stream, &latencyAddress, 0, nil, &valueSize, &value) == noErr else {
            return 0
        }
        return value
    }
}
