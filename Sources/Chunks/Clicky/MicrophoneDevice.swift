import AVFoundation
import CoreAudio
import Foundation

/// What CoreAudio says about the default input, right now.
///
/// `kAUStartIO` refusing with `'what'` (2003329396) has two causes that look identical from the
/// app's side: the device has not finished being **released** by a process that just died, and
/// another process is **holding** it. The first is cured by waiting — which is what the retry
/// schedule does — and the second is not, so telling a user to "press the key again" about a
/// microphone Chrome is streaming from sends him pressing forever.
///
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` is the public API that separates them. It says
/// whether any client is running the device, which while Chunks is not recording means somebody
/// else.
enum MicrophoneDevice {

    struct Report {
        /// The device's own name, or nil when macOS has no default input at all.
        let name: String?
        /// Nominal sample rate; 0 means the device is not actually up.
        let hertz: Double
        /// Whether some process is streaming from it right now.
        let runningSomewhere: Bool

        var oneLine: String {
            guard let name else { return "no default input device at all" }
            return "\"\(name)\" at \(Int(hertz)) Hz · in use by a process: "
                + (runningSomewhere ? "yes" : "no")
        }
    }

    static var report: Report {
        guard let device = defaultInputDevice() else {
            return Report(name: nil, hertz: 0, runningSomewhere: false)
        }
        return Report(name: stringProperty(device, kAudioObjectPropertyName),
                      hertz: nominalSampleRate(device),
                      runningSomewhere: (scalarProperty(
                        device, kAudioDevicePropertyDeviceIsRunningSomewhere, zero: UInt32(0))
                        as UInt32?) == 1)
    }

    /// The device's rate, asked in the two scopes that answer, because a device that is up but
    /// idle reports 0 globally on some Macs — and a 0 read as "no microphone" is a wrong diagnosis
    /// sent to a user whose hardware is fine.
    private static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeGlobal] {
            if let rate: Float64 = scalarProperty(device, kAudioDevicePropertyNominalSampleRate,
                                                  zero: 0, scope: scope), rate > 0 {
                return rate
            }
        }
        return 0
    }

    // MARK: - The three C calls, wrapped once

    private static func defaultInputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector)
        -> String? {
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    private static func scalarProperty<T>(_ device: AudioDeviceID,
                                          _ selector: AudioObjectPropertySelector,
                                          zero: T,
                                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> T? {
        var value = zero
        var size = UInt32(MemoryLayout<T>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
}
