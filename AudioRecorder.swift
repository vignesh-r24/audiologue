import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreAudio

class AudioRecorder: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var isRecording = false
    private let sampleRate: Double = 44100.0
    private var startTime: CMTime?
    
    // Microphone Recording
    private let audioEngine = AVAudioEngine()
    private var micFile: AVAudioFile?
    
    private let tempSysURL: URL
    private let tempMicURL: URL
    private let outputURL: URL
    
    init(outputURL: URL) {
        let tempDir = FileManager.default.temporaryDirectory
        self.tempSysURL = tempDir.appendingPathComponent("temp_sys.m4a")
        self.tempMicURL = tempDir.appendingPathComponent("temp_mic.caf")
        self.outputURL = outputURL
        super.init()
    }
    
    func start() async throws {
        // Clear any old temp files
        try? FileManager.default.removeItem(at: tempSysURL)
        try? FileManager.default.removeItem(at: tempMicURL)
        
        isRecording = true
        startTime = nil
        
        // 1. Start ScreenCaptureKit for System Audio
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareableContent.displays.first else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found for ScreenCaptureKit"])
        }
        
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.queueDepth = 5
        
        // Setup AssetWriter for System Audio
        let writer = try AVAssetWriter(outputURL: tempSysURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 128000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) {
            writer.add(input)
        }
        self.assetWriter = writer
        self.assetWriterInput = input
        
        writer.startWriting()
        
        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try scStream.addStreamOutput(self, type: SCStreamOutputType.audio, sampleHandlerQueue: DispatchQueue(label: "com.audiologue.systemAudioQueue"))
        try await scStream.startCapture()
        self.stream = scStream
        
        // 2. Start AVAudioEngine for Microphone Audio
        let inputNode = audioEngine.inputNode
        
        // Query and apply the default system input device ID explicitly
        if let defaultInputID = getDefaultInputDevice() {
            print("[Recorder] Current default system input device ID: \(defaultInputID)")
            try? setInputDevice(defaultInputID)
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        print("[Recorder] Microphone input channel count: \(recordingFormat.channelCount), sample rate: \(recordingFormat.sampleRate)")
        
        // Create AVAudioFile with standard recording format (PCM)
        let micSettings = recordingFormat.settings
        self.micFile = try AVAudioFile(forWriting: tempMicURL, settings: micSettings)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, time) in
            guard let self = self, self.isRecording else { return }
            do {
                try self.micFile?.write(from: buffer)
            } catch {
                print("Failed to write microphone buffer: \(error)")
            }
        }
        
        try audioEngine.start()
        print("[Recorder] System audio and mic recorders started successfully.")
    }
    
    // CoreAudio Helper to get default input device
    private func getDefaultInputDevice() -> AudioDeviceID? {
        var deviceID = kAudioObjectUnknown
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        if status == noErr {
            return deviceID
        }
        return nil
    }
    
    // CoreAudio Helper to set device on inputNode
    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        let inputNode = audioEngine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            throw NSError(domain: "AudioRecorder", code: 10, userInfo: [NSLocalizedDescriptionKey: "Input node audio unit is nil"])
        }
        
        var tempDeviceID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &tempDeviceID,
            size
        )
        
        if status != noErr {
            throw NSError(domain: "AudioRecorder", code: 11, userInfo: [NSLocalizedDescriptionKey: "Failed to set input device, status: \(status)"])
        }
    }
    
    func stop() async throws {
        isRecording = false
        
        // Stop Microphone Recording
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        micFile = nil // Flushes file
        
        // Stop ScreenCaptureKit
        if let scStream = stream {
            try await scStream.stopCapture()
            stream = nil
        }
        
        // Finish AssetWriter
        if let writer = assetWriter, writer.status == .writing {
            assetWriterInput?.markAsFinished()
            await writer.finishWriting()
        }
        assetWriter = nil
        assetWriterInput = nil
        
        print("[Recorder] Mixing audio channels...")
        // Mix files
        try await mixAudioFiles(systemURL: tempSysURL, micURL: tempMicURL, outputURL: outputURL)
        
        // Clean up temp files
        try? FileManager.default.removeItem(at: tempSysURL)
        try? FileManager.default.removeItem(at: tempMicURL)
        print("[Recorder] Recording output finalized at \(outputURL.path)")
    }
    
    // SCStreamOutput Delegate method
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard isRecording, outputType == .audio else { return }
        guard sampleBuffer.numSamples > 0, CMSampleBufferIsValid(sampleBuffer) else { return }
        
        if assetWriter?.status == .unknown {
            return
        }
        
        if startTime == nil {
            startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            assetWriter?.startSession(atSourceTime: startTime!)
        }
        
        if let input = assetWriterInput, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
    
    private func mixAudioFiles(systemURL: URL, micURL: URL, outputURL: URL) async throws {
        let composition = AVMutableComposition()
        
        let systemAsset = AVURLAsset(url: systemURL)
        let micAsset = AVURLAsset(url: micURL)
        
        guard let compositionSystemTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionMicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "AudioRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create composition tracks"])
        }
        
        let systemAssetTracks = try await systemAsset.loadTracks(withMediaType: .audio)
        let micAssetTracks = try await micAsset.loadTracks(withMediaType: .audio)
        
        guard let systemTrack = systemAssetTracks.first,
              let micTrack = micAssetTracks.first else {
            throw NSError(domain: "AudioRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Audio tracks not found in source assets"])
        }
        
        let systemDuration = try await systemAsset.load(.duration)
        let micDuration = try await micAsset.load(.duration)
        
        try compositionSystemTrack.insertTimeRange(CMTimeRange(start: .zero, duration: systemDuration), of: systemTrack, at: .zero)
        try compositionMicTrack.insertTimeRange(CMTimeRange(start: .zero, duration: micDuration), of: micTrack, at: .zero)
        
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "AudioRecorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }
        
        try? FileManager.default.removeItem(at: outputURL)
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        
        await exportSession.export()
        
        if exportSession.status == .failed {
            throw exportSession.error ?? NSError(domain: "AudioRecorder", code: 5, userInfo: [NSLocalizedDescriptionKey: "Export session failed without error"])
        }
    }
}
