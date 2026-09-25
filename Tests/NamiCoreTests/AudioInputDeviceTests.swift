import Foundation
import Testing
@testable import NamiAudio

@Test func missingMicrophoneDoesNotResolveToSystemDefault() {
    #expect(throws: AudioInputError.self) {
        try AudioInputDevice.deviceID(for: "nami-missing-device-" + UUID().uuidString)
    }
}
