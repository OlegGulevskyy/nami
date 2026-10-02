import CoreAudio
import Foundation

/// The microphone's hardware input volume, the same control as System Settings → Sound,
/// so a change applies to every app. nil means the device offers no settable volume.
public enum AudioInputVolume {
    /// A nil UID follows the system default microphone.
    public static func volume(deviceUID: String?) -> Double? {
        guard let device = device(for: deviceUID) else { return nil }
        let values = elements(of: device).compactMap { element -> Float32? in
            var address = address(element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
        }
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    @discardableResult
    public static func setVolume(_ volume: Double, deviceUID: String?) -> Bool {
        guard let device = device(for: deviceUID) else { return false }
        let elements = elements(of: device)
        guard !elements.isEmpty else { return false }
        var value = Float32(min(1, max(0, volume)))
        return elements.allSatisfy { element in
            var address = address(element)
            return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
        }
    }

    private static func device(for uid: String?) -> AudioDeviceID? {
        guard let uid else { return AudioInputDevice.defaultDeviceID() }
        return try? AudioInputDevice.deviceID(for: uid)
    }

    /// Most devices expose one main control; others only per-channel ones, which move together.
    private static func elements(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        if settable(device, kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        let channels = inputChannelCount(device)
        guard channels > 0 else { return [] }
        return (1...channels).filter { settable(device, $0) }
    }

    private static func settable(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Bool {
        var address = address(element)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    private static func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput, mElement: element)
    }
}
