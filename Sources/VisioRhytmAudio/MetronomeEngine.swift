import AVFoundation
import Observation
import os
import VisioRhytmCore

private struct AudioClockSnapshot: Sendable {
    var frame: Int64 = 0
    var hostTime: UInt64 = 0
    var bufferFrames: Int64 = 0
}

/// The render callback owns the counter. The main actor only reads snapshots.
final class RenderState: @unchecked Sendable {
    let plan: PlaybackPlan
    private let clock = OSAllocatedUnfairLock(initialState: AudioClockSnapshot())
    private var frame: Int64 = 0
    init(plan: PlaybackPlan) { self.plan = plan }
    // Build the callback in a nonisolated context. Defining it inside the
    // @MainActor transport would inherit actor isolation and trap on the audio thread.
    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] isSilence, timestamp, count, buffers in
            isSilence.pointee = false
            return render(timestamp: timestamp.pointee, count: count, buffers: buffers)
        }
    }
    func render(timestamp: AudioTimeStamp, count: AVAudioFrameCount, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        // The only lock is once per buffer; no allocations, file IO or UI work here.
        clock.withLock { $0 = AudioClockSnapshot(frame: frame, hostTime: timestamp.mHostTime, bufferFrames: Int64(count)) }
        for i in 0..<Int(count) {
            let value = plan.sample(frame: frame + Int64(i))
            for buffer in list {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for channel in 0..<Int(buffer.mNumberChannels) {
                    data[i * Int(buffer.mNumberChannels) + channel] = value
                }
            }
        }
        frame += Int64(count)
        return noErr
    }
    func currentFrame(latency: Double) -> Double {
        let snapshot = clock.withLock { $0 }
        guard snapshot.hostTime > 0 else { return 0 }
        let now = mach_absolute_time()
        let delta = now >= snapshot.hostTime
            ? AVAudioTime.seconds(forHostTime: now - snapshot.hostTime)
            : -AVAudioTime.seconds(forHostTime: snapshot.hostTime - now)
        // Extrapolate only within the current buffer; an interrupted engine must not advance UI time.
        let elapsed = min(Double(snapshot.bufferFrames), delta * plan.sampleRate)
        return max(0, Double(snapshot.frame) + elapsed - latency * plan.sampleRate)
    }
}

@MainActor @Observable
public final class MetronomeEngine {
    public private(set) var isPlaying = false
    public private(set) var stoppedTicks: Int64 = 0
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var source: AVAudioSourceNode?
    @ObservationIgnored private var renderState: RenderState?
    @ObservationIgnored private var outputLatency: Double = 0
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private var playbackActivity: NSObjectProtocol?
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    public var onFailure: ((String) -> Void)?
    public init() {}

    public func currentTicks() -> Double {
        guard isPlaying, let renderState else { return Double(stoppedTicks) }
        return renderState.plan.position(frame: renderState.currentFrame(latency: outputLatency))
    }
    public func start(project: Project) throws {
        guard !isPlaying else { return }
        try ProjectStore().validate(project)
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw ProjectError.invalid("устройство вывода звука недоступно")
        }
        var renderingProject = project
        renderingProject.metronomeSettings.volume = 1
        if !project.metronomeSettings.loopEnabled && stoppedTicks >= RhythmEngine.playbackRange(project: project).upperBound {
            stoppedTicks = RhythmEngine.playbackRange(project: project).lowerBound
        }
        let state = RenderState(plan: PlaybackPlan(project: renderingProject, startTicks: stoppedTicks, sampleRate: rate))
        let node = state.makeSourceNode(format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Float(project.metronomeSettings.volume)
        engine.prepare()
        try engine.start()
        self.engine = engine
        source = node
        renderState = state
        outputLatency = engine.outputNode.presentationLatency
        playbackActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "VisioRhytm metronome playback")
        isPlaying = true
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.stop()
                self.onFailure?("Аудиоустройство изменилось. Выберите устройство вывода в macOS и снова нажмите Play.")
            }
        }
        if state.plan.endTicks != nil {
            completionTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(10)) }
                    catch { return }
                    guard let self, self.renderState === state, self.isPlaying else { return }
                    // Only poll the audio clock. Musical time is never advanced by this task.
                    if state.plan.isFinished(frame: state.currentFrame(latency: self.outputLatency)) {
                        self.stop()
                        return
                    }
                }
            }
        }
    }
    public func stop() {
        stoppedTicks = Int64(currentTicks())
        completionTask?.cancel()
        completionTask = nil
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        if let playbackActivity { ProcessInfo.processInfo.endActivity(playbackActivity) }
        playbackActivity = nil
        engine?.stop()
        engine = nil
        source = nil
        renderState = nil
        isPlaying = false
    }
    public func returnToStart(project: Project) throws {
        let wasPlaying = isPlaying
        stop()
        stoppedTicks = RhythmEngine.playbackRange(project: project).lowerBound
        if wasPlaying { try start(project: project) }
    }
    public func reconfigure(project: Project) throws {
        guard isPlaying else { return }
        stop()
        if !project.metronomeSettings.loopEnabled && stoppedTicks >= RhythmEngine.playbackRange(project: project).upperBound {
            stoppedTicks = RhythmEngine.playbackRange(project: project).upperBound
            return
        }
        try start(project: project)
    }
    /// Reconcile a stopped cursor as well as running playback with edited bounds.
    public func updatePlaybackRange(project: Project) throws {
        if isPlaying {
            try reconfigure(project: project)
        } else {
            let range = RhythmEngine.playbackRange(project: project)
            if stoppedTicks < range.lowerBound || stoppedTicks >= range.upperBound {
                stoppedTicks = range.lowerBound
            }
        }
    }
    public func setVolume(_ volume: Double) {
        engine?.mainMixerNode.outputVolume = Float(min(1, max(0, volume)))
    }
}
