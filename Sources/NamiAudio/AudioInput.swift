@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import NamiCore

public enum AudioInputError: Error, LocalizedError {
    case permissionDenied, invalidFormat, conversionFailed, overflow, deviceUnavailable, deviceSelectionFailed, noAudioReceived
    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Enable microphone access for Nami (or your terminal when using the CLI) in System Settings → Privacy & Security → Microphone."
        case .invalidFormat: "No usable audio input format."
        case .conversionFailed: "Audio conversion failed."
        case .overflow: "Audio consumer fell behind; recording was cancelled rather than dropping samples."
        case .deviceUnavailable: "Your selected microphone is unavailable. Reconnect it or choose another microphone."
        case .deviceSelectionFailed: "Could not use the selected microphone. Reconnect it or choose another microphone."
        case .noAudioReceived: "No sound arrived from the microphone. Reconnect it or choose another microphone in Settings."
        }
    }
}

/// Converter is used serially on the audio tap, or synchronously by file loading.
private final class PCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    init(input: AVAudioFormat) throws {
        guard input.sampleRate > 0, input.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: AudioChunk.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output)
        else { throw AudioInputError.invalidFormat }
        self.output = output
        self.converter = converter
        converter.downmix = true
    }

    func convert(_ input: AVAudioPCMBuffer?, end: Bool = false) throws -> [Float] {
        let supplied = SampleCursor()
        var samples: [Float] = []
        while true {
            let capacity: AVAudioFrameCount = 4096
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
                throw AudioInputError.conversionFailed
            }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, state in
                if supplied.count == 0, let input {
                    supplied.count = 1
                    state.pointee = .haveData
                    return input
                }
                state.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            if let channel = buffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            switch status {
            case .error: throw AudioInputError.conversionFailed
            case .inputRanDry, .endOfStream: return samples
            case .haveData: continue
            @unknown default: throw AudioInputError.conversionFailed
            }
        }
    }
}

public enum AudioFile {
    public static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let converter = try PCMConverter(input: file.processingFormat)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw AudioInputError.invalidFormat
        }
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            samples += try converter.convert(buffer)
        }
        samples += try converter.convert(nil, end: true)
        return samples
    }

    public static func write(_ samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else { throw EngineError.noAudio }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate,
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw AudioInputError.invalidFormat }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        try file.write(from: buffer)
    }
}

/// Bounded stream; copies tap-owned memory before handing samples to consumers.
/// No audio is persisted. The caller must stop on completion, error or cancellation.
@MainActor
public protocol AudioCapturing: AnyObject {
    var inputDescription: String { get }
    func start() async throws -> AsyncThrowingStream<AudioChunk, Error>
    func stop()
}

@MainActor
public final class MicrophoneCapture: AudioCapturing {
    public private(set) var inputDescription = "Unknown microphone"
    private let engine = AVAudioEngine()
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private var installed = false
    private var converter: PCMConverter?
    private var cursor: SampleCursor?
    private var deviceInput: DeviceInput?
    private let deviceUID: String?
    public init(deviceUID: String? = nil) { self.deviceUID = deviceUID }

    public static func defaultDeviceName() -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return "System default microphone"
        }
        return name(of: device)
    }

    public func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        guard !installed, deviceInput == nil else { throw EngineError.invalidState }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AudioInputError.permissionDenied }
        }
        let pair = AsyncThrowingStream<AudioChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        if let deviceUID {
            // On macOS AVAudioEngine's input and output share one I/O unit, and
            // switching only its input device leaves a stale format: depending on
            // the device the engine fails to start or runs without delivering
            // buffers. An input-only HAL unit opens exactly the selected device.
            let device = try AudioInputDevice.deviceID(for: deviceUID)
            let input = try DeviceInput(device: device)
            inputDescription = "\(Self.name(of: device)): \(Int(input.format.sampleRate)) Hz, \(input.format.channelCount) channel(s)"
            let tap = try makeTap(format: input.format, continuation: pair.continuation)
            deviceInput = input
            do { try input.start(tap) } catch { stop(); throw error }
            return pair.stream
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        inputDescription = "\(Self.deviceName(input)): \(Int(format.sampleRate)) Hz, \(format.channelCount) channel(s)"
        try installTap(on: input, format: format, continuation: pair.continuation)
        installed = true
        do { try engine.start() } catch { stop(); throw error }
        return pair.stream
    }

    /// Kept separate so tests can drive the exact installed callback from an
    /// audio-style background queue without microphone access or a running engine.
    func installTap(on node: AVAudioNode, format: AVAudioFormat,
                    continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation) throws {
        let tap = try makeTap(format: format, continuation: continuation)
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in tap(buffer) }
    }

    private func makeTap(format: AVAudioFormat, continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation)
        throws -> @Sendable (AVAudioPCMBuffer) -> Void {
        self.continuation = continuation
        let converter = try PCMConverter(input: format)
        // Audio callbacks for one capture are serialized.
        let cursor = SampleCursor()
        self.converter = converter
        self.cursor = cursor
        // Audio callbacks run on an audio thread. Explicit Sendable prevents the
        // closure inheriting MainActor isolation from registration; otherwise
        // Swift traps on the first buffer with dispatch_assert_queue.
        // Captures are tap-owned state and a thread-safe stream continuation;
        // never capture the MainActor-isolated MicrophoneCapture instance here.
        return { @Sendable buffer in
            do {
                let samples = try converter.convert(buffer)
                guard !samples.isEmpty else { return }
                let chunk = AudioChunk(samples: samples, timestamp: Double(cursor.count) / AudioChunk.sampleRate)
                cursor.count += samples.count
                if case .dropped = continuation.yield(chunk) {
                    continuation.finish(throwing: AudioInputError.overflow)
                }
            } catch { continuation.finish(throwing: error) }
        }
    }

    public func stop() {
        engine.stop()
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
        deviceInput?.stop()
        deviceInput = nil
        // The tap has stopped; drain the resampler's remaining frames before EOF.
        if let converter, let cursor, let continuation {
            do {
                let tail = try converter.convert(nil, end: true)
                if !tail.isEmpty {
                    if case .dropped = continuation.yield(AudioChunk(samples: tail,
                        timestamp: Double(cursor.count) / AudioChunk.sampleRate)) {
                        continuation.finish(throwing: AudioInputError.overflow)
                    }
                }
            } catch { continuation.finish(throwing: error) }
        }
        continuation?.finish()
        continuation = nil
        converter = nil
        cursor = nil
    }

    private static func deviceName(_ input: AVAudioInputNode) -> String {
        guard let unit = input.audioUnit else { return "Unknown microphone" }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, &size) == noErr else { return "Unknown microphone" }
        return name(of: device)
    }

    static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let result = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard result == noErr,
              let name else { return "Unknown microphone" }
        return name as String
    }
}

private final class SampleCursor: @unchecked Sendable { var count = 0 }

/// Input-only HAL unit bound to one device, delivering its native format.
/// Buffers are owned here and only touched by the serialized input callback,
/// or by stop() once the device no longer calls back.
private final class DeviceInput: @unchecked Sendable {
    let format: AVAudioFormat
    private let unit: AudioUnit
    private let buffer: AVAudioPCMBuffer
    // Devices call back in small slices; batching ~100 ms keeps the bounded
    // stream's headroom similar to an engine tap.
    private let pending: AVAudioPCMBuffer
    private let batchFrames: AVAudioFrameCount
    private var tap: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var running = false

    init(device: AudioDeviceID) throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        var instance: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else {
            throw AudioInputError.deviceSelectionFailed
        }
        do {
            var enable: UInt32 = 1, disable: UInt32 = 0, device = device
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var frames: UInt32 = 0
            var framesSize = UInt32(MemoryLayout<UInt32>.size)
            // Element 1 is the input side and element 0 the output side of a HAL unit.
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)))
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)))
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)))
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 1, &hardware, &size))
            // The HAL unit converts sample format but not rate, so keep the device rate.
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                      channels: hardware.mChannelsPerFrame, interleaved: false) else {
                throw AudioInputError.invalidFormat
            }
            var client = format.streamDescription.pointee
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output, 1, &client, size))
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global, 0, &frames, &framesSize))
            let capacity = max(frames, 4096), batchFrames = AVAudioFrameCount(format.sampleRate / 10)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
                  let pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: batchFrames + capacity) else {
                throw AudioInputError.invalidFormat
            }
            self.format = format
            self.buffer = buffer
            self.pending = pending
            self.batchFrames = batchFrames
            self.unit = unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    deinit { AudioComponentInstanceDispose(unit) }

    func start(_ tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        self.tap = tap
        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, timestamp, bus, frames, _ in
            Unmanaged<DeviceInput>.fromOpaque(refCon).takeUnretainedValue()
                .render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try Self.check(AudioUnitInitialize(unit))
        running = true
        try Self.check(AudioOutputUnitStart(unit))
    }

    /// Returns once the device has stopped calling back.
    func stop() {
        guard running else { return }
        running = false
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        if pending.frameLength > 0 { tap?(pending); pending.frameLength = 0 }
        tap = nil
    }

    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        timestamp: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32) -> OSStatus {
        guard frames <= buffer.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        buffer.frameLength = frames
        let channels = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for index in channels.indices { channels[index].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size) }
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr, let source = buffer.floatChannelData, let target = pending.floatChannelData else { return status }
        for channel in 0..<Int(format.channelCount) {
            (target[channel] + Int(pending.frameLength)).update(from: source[channel], count: Int(frames))
        }
        pending.frameLength += frames
        // The tap converts synchronously, so the pending buffer can be reused.
        if pending.frameLength >= batchFrames { tap?(pending); pending.frameLength = 0 }
        return status
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioInputError.deviceSelectionFailed }
    }
}
