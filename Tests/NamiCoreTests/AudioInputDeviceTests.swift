import Foundation
import Testing
@testable import NamiAudio

@Test func missingMicrophoneDoesNotResolveToSystemDefault() {
    #expect(throws: AudioInputError.self) {
        try AudioInputDevice.deviceID(for: "nami-missing-device-" + UUID().uuidString)
    }
}

@Test func missingMicrophoneHasNoInputVolume() {
    let uid = "nami-missing-device-" + UUID().uuidString
    #expect(AudioInputVolume.volume(deviceUID: uid) == nil)
    #expect(!AudioInputVolume.setVolume(0.5, deviceUID: uid))
}
