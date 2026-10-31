import AVFoundation
import Foundation
import SaydropCore
import SaydropRealtime

private enum AudioPipelineLimits {
    static let targetSampleRate = 16_000.0
    static let targetChannels: AVAudioChannelCount = 1
    static let targetBytesPerFrame = 2
    static let wavHeaderBytes = 44
    static let maximumOutputFrames = Int(SaydropDefaults.captureLimit * targetSampleRate)
    static let ringCapacityFrames: UInt32 = 32_768
    static let acknowledgementTimeoutNanoseconds: UInt64 = 5_000_000_000
    static let workerTickMilliseconds = 10
    static let levelIntervalNanoseconds: UInt64 = 50_000_000
}

public struct CapturedAudio {
    public let wav: Data
    public let duration: TimeInterval
    public let frameCount: Int
    public let rms: Double

    public init(wav: Data, duration: TimeInterval, frameCount: Int, rms: Double) {
        self.wav = wav
        self.duration = duration
        self.frameCount = frameCount
        self.rms = rms
    }
}

@MainActor
public protocol AudioCapturing: AnyObject {
    var onLevel: ((UUID, Double) -> Void)? { get set }
    var onFailure: ((UUID, String) -> Void)? { get set }
    var onLimit: ((UUID) -> Void)? { get set }

    func start(id: UUID) async throws
    func pause(id: UUID)
    func resume(id: UUID) async throws
    func finish(id: UUID) async throws -> CapturedAudio
    func cancel(id: UUID)
}

@MainActor
extension AudioCapturing {
    public var onLimit: ((UUID) -> Void)? { get { nil } set {} }
}

public enum AudioPipelineError: LocalizedError {
    case captureAlreadyActive
    case invalidSession
    case resumeAlreadyInProgress
    case finishAlreadyInProgress
    case unsupportedInputFormat
    case ringAllocationFailed
    case acknowledgementTimedOut
    case cancelled
    case ringOverflow
    case invalidInputBuffer
    case conversionFailed(String)
    case emptyAudio
    case nearSilent(rms: Double)
    case maximumDuration
    case audioTooLarge
    case deviceConfigurationChanged

    public var errorDescription: String? {
        switch self {
        case .captureAlreadyActive:
            return "A recording session is already in progress."
        case .invalidSession:
            return "The recording session has ended or does not match."
        case .resumeAlreadyInProgress:
            return "Recording is resuming. Do not repeat the action."
        case .finishAlreadyInProgress:
            return "Audio is being prepared. Do not finish the session again."
        case .unsupportedInputFormat:
            return "The current input device does not provide usable Float32 PCM audio."
        case .ringAllocationFailed:
            return "Could not reserve an audio buffer for this recording."
        case .acknowledgementTimedOut:
            return "No valid audio buffer was received from the input device."
        case .cancelled:
            return "Recording cancelled."
        case .ringOverflow:
            return "Audio processing did not finish in time. Recording stopped to avoid losing or overwriting data."
        case .invalidInputBuffer:
            return "The input device returned an unreadable audio buffer."
        case .conversionFailed:
            return "Could not convert this recording."
        case .emptyAudio:
            return "No usable audio was captured."
        case .nearSilent:
            return "The recording was too quiet and was not submitted."
        case .maximumDuration:
            return "The 120-second recording limit was reached. Microphone capture stopped."
        case .audioTooLarge:
            return "The recording exceeds the in-memory upload size limit."
        case .deviceConfigurationChanged:
            return "The input device configuration changed. Recording stopped."
        }
    }
}

/// The realtime tap owns no Swift state. It only writes native Float32 frames
/// into `SaydropRealtime`'s preallocated SPSC ring. Conversion, level delivery,
/// WAV assembly, validation, and all actor callbacks run off the audio thread.
@MainActor
public final class AudioPipeline: AudioCapturing {
    public var onLevel: ((UUID, Double) -> Void)?
    public var onFailure: ((UUID, String) -> Void)?
    public var onLimit: ((UUID) -> Void)?

    private let engine: AVAudioEngine
    private let workerQueue = DispatchQueue(label: "com.saydrop.audio.conversion", qos: .userInitiated)
    private let silenceRMSFloor: Double?
    private var active: CaptureSession?
    private var configurationObserver: NSObjectProtocol?

    /// A nil floor keeps quiet recordings for callers that only need a marker.
    /// A non-nil value in 0...1 makes finish fail with an explicit near-silence
    /// error after WAV validation, without opening a new recording path.
    public init(silenceRMSFloor: Double? = nil) {
        self.engine = AVAudioEngine()
        self.silenceRMSFloor = silenceRMSFloor.flatMap { (0...1).contains($0) ? $0 : nil }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        if active?.tapInstalled == true { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
    }

    public func start(id: UUID) async throws {
        try Task.checkCancellation()
        guard active == nil else { throw AudioPipelineError.captureAlreadyActive }

        let session = try makeSession(id: id)
        active = session
        observeConfiguration(for: session)
        startWorker(session)

        do {
            try startHardware(for: session)
            try await awaitFirstEffectiveBuffer(for: session)
        } catch {
            if active === session {
                tearDown(session, resumeFinishWith: error)
            }
            throw error
        }
    }

    public func pause(id: UUID) {
        guard let session = active, session.id == id, !session.finishing, !session.paused else { return }
        stopHardware(for: session)
        session.paused = true
    }

    public func resume(id: UUID) async throws {
        try Task.checkCancellation()
        guard let session = active, session.id == id, session.paused, !session.finishing else {
            throw AudioPipelineError.invalidSession
        }
        guard !session.resuming else { throw AudioPipelineError.resumeAlreadyInProgress }

        session.resuming = true
        do {
            try startHardware(for: session)
            try await awaitFirstEffectiveBuffer(for: session)
            guard active === session else { throw AudioPipelineError.cancelled }
            session.paused = false
            session.resuming = false
        } catch {
            session.resuming = false
            if active === session {
                tearDown(session, resumeFinishWith: error)
            }
            throw error
        }
    }

    public func finish(id: UUID) async throws -> CapturedAudio {
        guard let session = active, session.id == id else { throw AudioPipelineError.invalidSession }
        guard !session.finishing else { throw AudioPipelineError.finishAlreadyInProgress }
        session.finishing = true
        stopHardware(for: session)
        session.timer?.cancel()
        session.timer = nil

        return try await withCheckedThrowingContinuation { continuation in
            session.finishContinuation = continuation
            workerQueue.async {
                Self.finishOnWorker(session)
            }
        }
    }

    public func cancel(id: UUID) {
        guard let session = active, session.id == id else { return }
        tearDown(session, resumeFinishWith: AudioPipelineError.cancelled)
    }

    /// Explicit lifecycle cleanup for hosts that discard the capture service.
    public func shutdown() {
        if let active {
            tearDown(active, resumeFinishWith: AudioPipelineError.cancelled)
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    // MARK: Test-only deterministic conversion support

    /// Uses the same continuous converter and flush path as capture, but accepts
    /// synthetic planar Float32 PCM. It never creates an AVAudioEngine tap or
    /// requests microphone access.
    static func convertPlanarFloat32ForTesting(
        _ channels: [[Float]],
        sampleRate: Double,
        silenceRMSFloor: Double? = nil
    ) throws -> CapturedAudio {
        guard let first = channels.first, !first.isEmpty,
              channels.allSatisfy({ $0.count == first.count }), sampleRate > 0 else {
            throw AudioPipelineError.emptyAudio
        }
        guard channels.count <= 32 else { throw AudioPipelineError.unsupportedInputFormat }

        let worker = try PCMConversionWorker(
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count),
            maximumFrames: AudioPipelineLimits.maximumOutputFrames,
            maximumPCMBytes: SaydropDefaults.maximumAudioBytes - AudioPipelineLimits.wavHeaderBytes
        )
        let framesPerChunk = worker.maximumInputFrames
        var cursor = 0
        while cursor < first.count {
            let frameCount = min(framesPerChunk, first.count - cursor)
            try worker.consumePlanarForTesting(channels, offset: cursor, frameCount: frameCount)
            cursor += frameCount
            if worker.reachedLimit { break }
        }
        return try worker.finish(silenceRMSFloor: silenceRMSFloor)
    }

    // MARK: Capture setup and realtime boundary

    private func makeSession(id: UUID) throws -> CaptureSession {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.commonFormat == .pcmFormatFloat32,
              inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              inputFormat.channelCount <= 32 else {
            throw AudioPipelineError.unsupportedInputFormat
        }
        guard let ring = sdrt_spsc_ring_create(AudioPipelineLimits.ringCapacityFrames, UInt32(inputFormat.channelCount)) else {
            throw AudioPipelineError.ringAllocationFailed
        }

        let session = CaptureSession(
            id: id,
            ring: ring,
            sampleRate: inputFormat.sampleRate,
            channels: inputFormat.channelCount,
            isInterleaved: inputFormat.isInterleaved,
            silenceRMSFloor: silenceRMSFloor
        )
        session.deliver = { [weak self, weak session] event in
            // The worker, never the realtime tap, schedules this main-actor hop.
            DispatchQueue.main.async {
                guard let self, let session else { return }
                self.handleWorkerEvent(event, from: session)
            }
        }
        return session
    }

    private func startHardware(for session: CaptureSession) throws {
        guard let ring = session.ring else { throw AudioPipelineError.cancelled }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.commonFormat == .pcmFormatFloat32,
              format.sampleRate == session.sampleRate,
              format.channelCount == session.channels,
              format.isInterleaved == session.isInterleaved else {
            throw AudioPipelineError.deviceConfigurationChanged
        }

        sdrt_spsc_ring_reset_first_buffer(ring)
        let isInterleaved = session.isInterleaved
        let channelCount = session.channels
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            // Realtime boundary: no Swift task, dispatch, lock, logging, I/O,
            // allocation, conversion, encryption, or WAV assembly is allowed.
            let frameCount = buffer.frameLength
            guard frameCount > 0, frameCount <= UInt32.max,
                  let channelData = buffer.floatChannelData else {
                sdrt_spsc_ring_mark_invalid_input(ring)
                return
            }

            let copied: Bool
            if isInterleaved {
                copied = sdrt_spsc_ring_write_interleaved_f32(ring, channelData.pointee, frameCount)
            } else {
                let planes = UnsafeRawPointer(channelData).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self)
                copied = sdrt_spsc_ring_write_planar_f32(ring, planes, frameCount)
            }
            if !copied {
                // The C ring atomically latches either overflow or invalid input.
                // Reporting is intentionally deferred to the worker.
                _ = channelCount
            }
        }
        session.tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
            session.hardwareRunning = true
        } catch {
            input.removeTap(onBus: 0)
            session.tapInstalled = false
            throw AudioPipelineError.conversionFailed("Could not start the input device.")
        }
    }

    private func stopHardware(for session: CaptureSession) {
        if session.tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            session.tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        session.hardwareRunning = false
    }

    private func awaitFirstEffectiveBuffer(for session: CaptureSession) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while true {
            try Task.checkCancellation()
            guard active === session, let ring = session.ring else { throw AudioPipelineError.cancelled }
            if sdrt_spsc_ring_has_first_buffer(ring) { return }
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            if elapsed >= AudioPipelineLimits.acknowledgementTimeoutNanoseconds {
                throw AudioPipelineError.acknowledgementTimedOut
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Worker and result delivery

    private func startWorker(_ session: CaptureSession) {
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        session.timer = timer
        timer.setEventHandler {
            Self.drainOnWorker(session)
        }
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(AudioPipelineLimits.workerTickMilliseconds),
            leeway: .milliseconds(2)
        )
        timer.resume()
    }

    nonisolated private static func drainOnWorker(_ session: CaptureSession) {
        guard let ring = session.ring else { return }
        if sdrt_spsc_ring_take_overflow(ring) {
            session.deliver?(.failed(AudioPipelineError.ringOverflow))
            return
        }
        if sdrt_spsc_ring_take_invalid_input(ring) {
            session.deliver?(.failed(AudioPipelineError.invalidInputBuffer))
            return
        }

        do {
            let worker = try worker(for: session)
            var newestLevel: Double?
            while !worker.reachedLimit {
                let frames = try worker.readAndConvert(from: ring)
                guard frames > 0 else { break }
                newestLevel = worker.latestBatchRMS
            }
            if let newestLevel, shouldEmitLevel(session: session) {
                session.deliver?(.level(newestLevel))
            }
            if worker.reachedLimit, !session.limitReported {
                session.limitReported = true
                session.deliver?(.captureLimitReached)
            }
        } catch {
            session.deliver?(.failed(error))
        }
    }

    nonisolated private static func finishOnWorker(_ session: CaptureSession) {
        do {
            guard let ring = session.ring else { throw AudioPipelineError.cancelled }
            if sdrt_spsc_ring_take_overflow(ring) { throw AudioPipelineError.ringOverflow }
            if sdrt_spsc_ring_take_invalid_input(ring) { throw AudioPipelineError.invalidInputBuffer }

            let worker = try worker(for: session)
            while !worker.reachedLimit {
                let frames = try worker.readAndConvert(from: ring)
                if frames == 0 { break }
            }
            let captured = try worker.finish(silenceRMSFloor: session.silenceRMSFloor)
            session.deliver?(.finished(.success(captured)))
        } catch {
            session.deliver?(.finished(.failure(error)))
        }
    }

    nonisolated private static func worker(for session: CaptureSession) throws -> PCMConversionWorker {
        if let worker = session.worker { return worker }
        let worker = try PCMConversionWorker(
            sampleRate: session.sampleRate,
            channels: session.channels,
            maximumFrames: AudioPipelineLimits.maximumOutputFrames,
            maximumPCMBytes: SaydropDefaults.maximumAudioBytes - AudioPipelineLimits.wavHeaderBytes
        )
        session.worker = worker
        return worker
    }

    nonisolated private static func shouldEmitLevel(session: CaptureSession) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - session.lastLevelTimestamp >= AudioPipelineLimits.levelIntervalNanoseconds else { return false }
        session.lastLevelTimestamp = now
        return true
    }

    private func handleWorkerEvent(_ event: WorkerEvent, from session: CaptureSession) {
        guard active === session else { return }
        switch event {
        case .level(let value):
            onLevel?(session.id, value)
        case .captureLimitReached:
            guard !session.finishing else { return }
            stopHardware(for: session)
            session.paused = true
            onLimit?(session.id)
        case .failed(let error):
            failCapture(session, error: error)
        case .finished(let result):
            switch result {
            case .success(let captured):
                session.finishContinuation?.resume(returning: captured)
                session.finishContinuation = nil
                stopObservingConfiguration()
                active = nil
            case .failure(let error):
                failCapture(session, error: error)
            }
        }
    }

    private func observeConfiguration(for session: CaptureSession) {
        stopObservingConfiguration()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self, weak session] _ in
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, self.active === session, !session.finishing else { return }
                self.failCapture(session, error: AudioPipelineError.deviceConfigurationChanged)
            }
        }
    }
    private func stopObservingConfiguration() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
    }

    private func failCapture(_ session: CaptureSession, error: Error) {
        guard active === session else { return }
        onFailure?(session.id, error.localizedDescription)
        tearDown(session, resumeFinishWith: error)
    }

    private func tearDown(_ session: CaptureSession, resumeFinishWith error: Error) {
        stopHardware(for: session)
        session.timer?.cancel()
        session.timer = nil
        if active === session { stopObservingConfiguration(); active = nil }
        if let continuation = session.finishContinuation {
            session.finishContinuation = nil
            continuation.resume(throwing: error)
        }
        workerQueue.async {
            session.worker?.discard()
        }
    }
}

private enum WorkerEvent {
    case level(Double)
    case captureLimitReached
    case failed(Error)
    case finished(Result<CapturedAudio, Error>)
}

/// Main actor owns UI/lifecycle fields; the realtime tap only retains its C ring
/// pointer, and the serial worker exclusively owns `worker` and level timing.
/// Dispatches carrying this instance are limited to that one serial worker; the
/// C ring uses acquire/release atomics for the producer/consumer boundary.
private final class CaptureSession: @unchecked Sendable {
    let id: UUID
    var ring: OpaquePointer?
    let sampleRate: Double
    let channels: AVAudioChannelCount
    let isInterleaved: Bool
    let silenceRMSFloor: Double?
    var tapInstalled = false
    var hardwareRunning = false
    var paused = false
    var resuming = false
    var finishing = false
    var timer: DispatchSourceTimer?
    var finishContinuation: CheckedContinuation<CapturedAudio, Error>?
    var deliver: ((WorkerEvent) -> Void)?

    // The following fields are only accessed by the single worker queue.
    var worker: PCMConversionWorker?
    var lastLevelTimestamp: UInt64 = 0
    var limitReported = false

    init(
        id: UUID,
        ring: OpaquePointer,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        isInterleaved: Bool,
        silenceRMSFloor: Double?
    ) {
        self.id = id
        self.ring = ring
        self.sampleRate = sampleRate
        self.channels = channels
        self.isInterleaved = isInterleaved
        self.silenceRMSFloor = silenceRMSFloor
    }

    deinit {
        if let ring {
            sdrt_spsc_ring_destroy(ring)
        }
    }
}

/// This type is only used on AudioPipeline's serial worker queue, except for
/// deterministic synthetic conversion tests. Each source buffer is supplied to
/// AVAudioConverter exactly once; .noDataNow then drains that call, and an
/// explicit .endOfStream pass flushes delayed resampler output without replaying
/// input frames.
private final class PCMConversionWorker {
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let nativeInput: UnsafeMutablePointer<Float>
    private let channelCount: Int
    private let maximumFrames: Int
    private let maximumPCMBytes: Int

    let maximumInputFrames: Int
    private(set) var latestBatchRMS: Double?
    private(set) var reachedLimit = false
    private var didFlush = false
    private var pcm = Data()
    private var frameCount = 0
    private var sumSquares = 0.0
    private var rmsSampleCount = 0

    init(sampleRate: Double, channels: AVAudioChannelCount, maximumFrames: Int, maximumPCMBytes: Int) throws {
        guard sampleRate.isFinite, (8_000...384_000).contains(sampleRate), (1...32).contains(channels) else {
            throw AudioPipelineError.unsupportedInputFormat
        }
        // Preserve every native channel in the ring; downmix only on this non-realtime worker.
        // Explicit mono input avoids SDK channel-layout assumptions for 3+ channels.
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ), let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioPipelineLimits.targetSampleRate,
            channels: AudioPipelineLimits.targetChannels,
            interleaved: true
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioPipelineError.unsupportedInputFormat
        }

        // A 65,536-frame output buffer stays bounded even for an 8 kHz source.
        // Leave resampler headroom and size source reads so a single input
        // callback cannot require a second input supply to drain output.
        let outputCapacity: AVAudioFrameCount = 65_536
        let safeOutputFrames = Int(outputCapacity) - 128
        let calculatedInputFrames = max(1, Int((Double(safeOutputFrames) * sampleRate / AudioPipelineLimits.targetSampleRate).rounded(.down)))
        let inputCapacity = AVAudioFrameCount(min(Int(AudioPipelineLimits.ringCapacityFrames), calculatedInputFrames))

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputCapacity),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw AudioPipelineError.ringAllocationFailed
        }

        self.converter = converter
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
        self.channelCount = Int(channels)
        self.maximumFrames = maximumFrames
        self.maximumPCMBytes = maximumPCMBytes
        self.maximumInputFrames = Int(inputCapacity)
        self.nativeInput = .allocate(capacity: Int(inputCapacity) * Int(channels))
        pcm.reserveCapacity(min(maximumPCMBytes, maximumFrames * AudioPipelineLimits.targetBytesPerFrame))
    }
    deinit { nativeInput.deallocate() }

    func readAndConvert(from ring: OpaquePointer) throws -> Int {
        guard let destination = inputBuffer.floatChannelData?.pointee else {
            throw AudioPipelineError.invalidInputBuffer
        }
        let count = sdrt_spsc_ring_read_interleaved_f32(ring, nativeInput, UInt32(maximumInputFrames))
        guard count > 0 else { return 0 }
        for frame in 0..<Int(count) {
            var sum = 0.0
            for channel in 0..<channelCount {
                let sample = nativeInput[frame * channelCount + channel]
                guard sample.isFinite else { throw AudioPipelineError.invalidInputBuffer }
                sum += Double(sample)
            }
            destination[frame] = Float(max(-1, min(1, sum / Double(channelCount))))
        }
        inputBuffer.frameLength = count
        try convert(inputBuffer)
        return Int(count)
    }

    func consumePlanarForTesting(_ channels: [[Float]], offset: Int, frameCount: Int) throws {
        guard channels.count == channelCount, frameCount <= maximumInputFrames,
              let destination = inputBuffer.floatChannelData?.pointee else {
            throw AudioPipelineError.invalidInputBuffer
        }
        for frame in 0..<frameCount {
            var sum = 0.0
            for channel in 0..<channelCount {
                let sample = channels[channel][offset + frame]
                guard sample.isFinite else { throw AudioPipelineError.invalidInputBuffer }
                sum += Double(sample)
            }
            destination[frame] = Float(max(-1, min(1, sum / Double(channelCount))))
        }
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        try convert(inputBuffer)
    }

    func finish(silenceRMSFloor: Double?) throws -> CapturedAudio {
        try flush()
        guard frameCount > 0 else { throw AudioPipelineError.emptyAudio }
        let wav = Self.makeWAV(fromPCM16: pcm)
        let metadata: WAVMetadata
        do {
            metadata = try WAVMetadata.parse(wav)
        } catch WAVMetadata.ValidationError.empty {
            throw AudioPipelineError.emptyAudio
        } catch WAVMetadata.ValidationError.tooLarge {
            throw AudioPipelineError.audioTooLarge
        } catch WAVMetadata.ValidationError.tooLong {
            // Exact output-frame clamping should avoid this. Preserve fail-closed
            // behavior if a future converter implementation violates it.
            throw AudioPipelineError.maximumDuration
        } catch {
            throw AudioPipelineError.conversionFailed("WAV validation failed.")
        }
        let rms = rmsSampleCount > 0 ? sqrt(sumSquares / Double(rmsSampleCount)) : 0
        if let silenceRMSFloor, rms < silenceRMSFloor {
            throw AudioPipelineError.nearSilent(rms: rms)
        }
        return CapturedAudio(wav: wav, duration: metadata.duration, frameCount: frameCount, rms: rms)
    }

    func discard() {
        converter.reset()
        pcm.removeAll(keepingCapacity: false)
        inputBuffer.frameLength = 0
        outputBuffer.frameLength = 0
    }

    private func convert(_ input: AVAudioPCMBuffer) throws {
        var suppliedInput = false
        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return input
            }
            try appendConvertedOutput()
            switch status {
            case .haveData:
                // Output filled before the converter reported input dry. Continue
                // with noDataNow; never hand the same AVAudioPCMBuffer back.
                continue
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw AudioPipelineError.conversionFailed(conversionError?.localizedDescription ?? "The audio converter returned an error.")
            @unknown default:
                throw AudioPipelineError.conversionFailed("The audio converter returned an unknown status.")
            }
        }
    }

    private func flush() throws {
        guard !didFlush else { return }
        didFlush = true
        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            try appendConvertedOutput()
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw AudioPipelineError.conversionFailed(conversionError?.localizedDescription ?? "Could not finish processing the audio.")
            @unknown default:
                throw AudioPipelineError.conversionFailed("Audio finalization returned an unknown status.")
            }
        }
    }

    private func appendConvertedOutput() throws {
        let outputFrames = Int(outputBuffer.frameLength)
        guard outputFrames > 0 else { return }
        guard let samples = outputBuffer.int16ChannelData?.pointee else {
            throw AudioPipelineError.conversionFailed("The converter did not provide PCM16 data.")
        }

        let allowedFrames = min(outputFrames, max(0, maximumFrames - frameCount))
        guard allowedFrames > 0 else {
            reachedLimit = true
            return
        }
        let byteCount = allowedFrames * AudioPipelineLimits.targetBytesPerFrame
        guard pcm.count <= maximumPCMBytes - byteCount else {
            throw AudioPipelineError.audioTooLarge
        }

        var batchSquares = 0.0
        for index in 0..<allowedFrames {
            let normalized = Double(samples[index]) / Double(Int16.max)
            let square = normalized * normalized
            batchSquares += square
            sumSquares += square
        }
        rmsSampleCount += allowedFrames
        latestBatchRMS = sqrt(batchSquares / Double(allowedFrames))
        pcm.append(UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: byteCount)
        frameCount += allowedFrames
        if allowedFrames < outputFrames || frameCount == maximumFrames {
            reachedLimit = true
        }
    }

    private static func makeWAV(fromPCM16 pcm: Data) -> Data {
        var wav = Data()
        wav.reserveCapacity(AudioPipelineLimits.wavHeaderBytes + pcm.count)
        wav.append(contentsOf: [82, 73, 70, 70]) // RIFF
        appendLittleEndian(UInt32(AudioPipelineLimits.wavHeaderBytes + pcm.count - 8), to: &wav)
        wav.append(contentsOf: [87, 65, 86, 69]) // WAVE
        wav.append(contentsOf: [102, 109, 116, 32]) // fmt 
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav) // PCM
        appendLittleEndian(UInt16(1), to: &wav) // mono
        appendLittleEndian(UInt32(AudioPipelineLimits.targetSampleRate), to: &wav)
        appendLittleEndian(UInt32(AudioPipelineLimits.targetSampleRate * Double(AudioPipelineLimits.targetBytesPerFrame)), to: &wav)
        appendLittleEndian(UInt16(AudioPipelineLimits.targetBytesPerFrame), to: &wav)
        appendLittleEndian(UInt16(16), to: &wav)
        wav.append(contentsOf: [100, 97, 116, 97]) // data
        appendLittleEndian(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
