import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
import ScreenCaptureKit

private struct Options {
    var delayMilliseconds = 2_000
    var listDevices = false

    static func parse() throws -> Options {
        var options = Options()
        var arguments = Array(CommandLine.arguments.dropFirst())

        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            switch argument {
            case "--delay-ms":
                guard let value = arguments.first, let milliseconds = Int(value), milliseconds >= 0 else {
                    throw MirrorError.usage("--delay-ms requires a non-negative integer")
                }
                arguments.removeFirst()
                options.delayMilliseconds = milliseconds
            case "--list-devices":
                options.listDevices = true
            case "--help", "-h":
                print(Self.help)
                exit(0)
            default:
                throw MirrorError.usage("unknown argument: \(argument)")
            }
        }

        return options
    }

    static let help = """
    MirrorPod — mirror Mac system audio to the built-in speakers while the normal output is a HomePod.

    Usage:
      mirrorpod [--delay-ms MILLISECONDS]
      mirrorpod --list-devices

    Options:
      --delay-ms MILLISECONDS  Delay the MacBook speakers to align with AirPlay (default: 2000).
      --list-devices           Show available output devices and exit.
      --help                   Show this help.
    """
}

enum MirrorError: LocalizedError {
    case usage(String)
    case coreAudio(String, OSStatus)
    case noBuiltInOutput
    case noDisplay
    case invalidAudioBuffer
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return "\(message)\n\n\(Options.help)"
        case .coreAudio(let operation, let status):
            return "\(operation) failed (Core Audio status \(status))."
        case .noBuiltInOutput:
            return "Could not find the Mac's built-in speaker output."
        case .noDisplay:
            return "Could not find a display to use for system-audio capture."
        case .invalidAudioBuffer:
            return "ScreenCaptureKit returned an unsupported audio buffer."
        case .permissionDenied:
            return "Screen & System Audio Recording permission is required. Enable it for MirrorPod, then launch MirrorPod again."
        }
    }
}

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let transportType: UInt32
    let outputChannels: UInt32

    var isBuiltInOutput: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn && outputChannels > 0
    }
}

enum AudioHardware {
    static func outputDevices() throws -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        )
        guard status == noErr else {
            throw MirrorError.coreAudio("Reading the audio-device list size", status)
        }

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        guard status == noErr else {
            throw MirrorError.coreAudio("Reading the audio-device list", status)
        }

        return ids.compactMap { id in
            guard let name = stringProperty(
                objectID: id,
                selector: kAudioObjectPropertyName
            ) else {
                return nil
            }

            let transport = uint32Property(
                objectID: id,
                selector: kAudioDevicePropertyTransportType
            ) ?? 0

            return AudioDevice(
                id: id,
                name: name,
                transportType: transport,
                outputChannels: outputChannelCount(deviceID: id)
            )
        }
        .filter { $0.outputChannels > 0 }
    }

    static func defaultOutputName() -> String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        return stringProperty(objectID: deviceID, selector: kAudioObjectPropertyName)
    }

    static func defaultOutputVolume() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }

        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = volumeAddress(element: element)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value: Float32 = 0
            var byteCount = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &value) == noErr {
                return value
            }
        }
        return nil
    }

    static func setDefaultOutputVolume(_ newValue: Float) throws {
        guard let deviceID = defaultOutputDeviceID() else {
            throw MirrorError.coreAudio("Finding the normal output", kAudioHardwareBadDeviceError)
        }

        var value = min(max(newValue, 0), 1)
        var didSetVolume = false
        var lastStatus: OSStatus = kAudioHardwareUnsupportedOperationError

        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = volumeAddress(element: element)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var isSettable = DarwinBoolean(false)
            let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
            guard settableStatus == noErr, isSettable.boolValue else {
                lastStatus = settableStatus
                continue
            }

            lastStatus = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            )
            if lastStatus == noErr {
                didSetVolume = true
            }
        }

        guard didSetVolume else {
            throw MirrorError.coreAudio("Changing the normal output volume", lastStatus)
        }
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &deviceID
        )
        guard status == noErr else { return nil }
        return deviceID
    }

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func stringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &byteCount,
                pointer
            )
        }
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private static func uint32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &byteCount,
            &value
        )
        return status == noErr ? value : nil
    }

    private static func outputChannelCount(deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount) == noErr,
              byteCount > 0
        else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, rawPointer) == noErr else {
            return 0
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + $1.mNumberChannels }
    }
}

final class AudioMirror: NSObject, SCStreamOutput, SCStreamDelegate {
    private let outputDevice: AudioDevice
    private var delayMilliseconds: Int
    private var volume: Float
    private let captureQueue = DispatchQueue(label: "MirrorPod.capture", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var stream: SCStream?
    private var captureFormat: AVAudioFormat?
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFramePosition = 0
    private var targetDelayFrames: AVAudioFramePosition = 0
    var onPlaybackStarted: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(outputDevice: AudioDevice, delayMilliseconds: Int, volume: Float = 1) {
        self.outputDevice = outputDevice
        self.delayMilliseconds = delayMilliseconds
        self.volume = min(max(volume, 0), 1)
        super.init()
    }

    func setVolume(_ newValue: Float) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            volume = min(max(newValue, 0), 1)
            engine.mainMixerNode.outputVolume = volume
        }
    }

    func setDelayMilliseconds(_ newValue: Int) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            delayMilliseconds = max(newValue, 0)

            guard let captureFormat else { return }
            targetDelayFrames = AVAudioFramePosition(
                captureFormat.sampleRate * Double(delayMilliseconds) / 1_000.0
            )

            while pendingFrames > targetDelayFrames, !pendingBuffers.isEmpty {
                let next = pendingBuffers.removeFirst()
                pendingFrames -= AVAudioFramePosition(next.frameLength)
                player.scheduleBuffer(next)
            }
        }
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw MirrorError.permissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw MirrorError.permissionDenied
        }

        guard let display = content.displays.first else {
            throw MirrorError.noDisplay
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.queueDepth = 3

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        captureQueue.sync {
            player.stop()
            engine.stop()
            pendingBuffers.removeAll()
            pendingFrames = 0
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if let onError {
            onError(error)
        } else {
            fputs("\nCapture stopped: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        do {
            let buffer = try makePCMBuffer(from: sampleBuffer)
            if captureFormat == nil {
                try configureEngine(format: buffer.format)
            }

            pendingBuffers.append(buffer)
            pendingFrames += AVAudioFramePosition(buffer.frameLength)

            while pendingFrames > targetDelayFrames, !pendingBuffers.isEmpty {
                let next = pendingBuffers.removeFirst()
                pendingFrames -= AVAudioFramePosition(next.frameLength)
                player.scheduleBuffer(next)
            }
        } catch {
            if let onError {
                onError(error)
            } else {
                fputs("\nAudio mirror error: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private func configureEngine(format: AVAudioFormat) throws {
        captureFormat = format
        targetDelayFrames = AVAudioFramePosition(
            format.sampleRate * Double(delayMilliseconds) / 1_000.0
        )

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        guard let audioUnit = engine.outputNode.audioUnit else {
            throw MirrorError.coreAudio("Accessing the built-in output unit", -1)
        }
        var deviceID = outputDevice.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw MirrorError.coreAudio("Routing MirrorPod to \(outputDevice.name)", status)
        }

        engine.prepare()
        engine.mainMixerNode.outputVolume = volume
        try engine.start()
        player.play()
        onPlaybackStarted?()
        print("Mirroring to \(outputDevice.name) with \(delayMilliseconds) ms delay.")
        print("Press Control-C to stop.")
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription)
        else {
            throw MirrorError.invalidAudioBuffer
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw MirrorError.invalidAudioBuffer
        }
        destination.frameLength = frameCount

        let sourceList = AudioBufferList.allocate(maximumBuffers: Int(format.channelCount))
        defer { sourceList.unsafeMutablePointer.deallocate() }
        var retainedBlockBuffer: CMBlockBuffer?
        let listByteCount = AudioBufferList.sizeInBytes(maximumBuffers: Int(format.channelCount))
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: sourceList.unsafeMutablePointer,
            bufferListSize: listByteCount,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else {
            throw MirrorError.coreAudio("Reading captured audio", status)
        }

        let destinationList = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceList.count == destinationList.count else {
            throw MirrorError.invalidAudioBuffer
        }

        for index in 0..<sourceList.count {
            guard let sourceData = sourceList[index].mData,
                  let destinationData = destinationList[index].mData
            else {
                throw MirrorError.invalidAudioBuffer
            }
            let byteCount = min(
                Int(sourceList[index].mDataByteSize),
                Int(destinationList[index].mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destinationList[index].mDataByteSize = UInt32(byteCount)
        }

        return destination
    }
}

#if !MENUBAR_APP
@main
private struct MirrorPodApp {
    static func main() async {
        do {
            let options = try Options.parse()
            let devices = try AudioHardware.outputDevices()

            if options.listDevices {
                for device in devices {
                    let builtIn = device.isBuiltInOutput ? " [built-in]" : ""
                    print("\(device.name) — \(device.outputChannels) channels\(builtIn)")
                }
                return
            }

            guard let builtInOutput = devices.first(where: \AudioDevice.isBuiltInOutput) else {
                throw MirrorError.noBuiltInOutput
            }

            if let defaultOutput = AudioHardware.defaultOutputName() {
                print("Normal Mac output: \(defaultOutput)")
                if defaultOutput == builtInOutput.name {
                    print("Warning: choose the HomePod as the Mac's normal Sound output before playing audio.")
                }
            }

            let mirror = AudioMirror(
                outputDevice: builtInOutput,
                delayMilliseconds: options.delayMilliseconds
            )
            try await mirror.start()
            print("Waiting for audio…")

            signal(SIGINT, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            interrupt.setEventHandler {
                Task {
                    print("\nStopping MirrorPod…")
                    await mirror.stop()
                    exit(0)
                }
            }
            interrupt.resume()
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in
                // The signal handler above exits the process. Keeping this task suspended lets
                // ScreenCaptureKit, AVAudioEngine, and Dispatch continue servicing their queues.
            }
        } catch {
            fputs("MirrorPod: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#endif
