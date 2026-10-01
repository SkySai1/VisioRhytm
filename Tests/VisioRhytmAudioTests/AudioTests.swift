import AVFoundation
import Foundation
import Testing
import VisioRhytmCore
@testable import VisioRhytmAudio

@Test func offlineEngineRendersActualSourceNode() throws {
    var project = Project()
    project.metronomeSettings.loopEnabled = false
    project.metronomeSettings.loopEndBar = 1
    project.bpm = 240
    let plan = PlaybackPlan(project: project, startTicks: 0, sampleRate: 48_000)
    let state = RenderState(plan: plan)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let engine = AVAudioEngine()
    let source = state.makeSourceNode(format: format)
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    try engine.start()
    defer { engine.stop() }
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
    var count: Int64 = 0
    var peak: Float = 0
    for _ in 0..<100 {
        #expect(try engine.renderOffline(1024, to: buffer) == .success)
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) {
            #expect(abs(samples[i] - plan.sample(frame: count + Int64(i))) < 1e-5)
            peak = max(peak, abs(samples[i]))
        }
        count += Int64(buffer.frameLength)
    }
    #expect(peak > 0.1)
    #expect(count == 102_400)
}

/// Opt in: uses the real output device, with volume zero, for three minutes.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VISIORHYTM_LIVE_AUDIO_TEST"] == "1"))
@MainActor func liveAudioClockAndTransport() async throws {
    var project = Project()
    project.bpm = 137
    project.metronomeSettings.volume = 0
    project.metronomeSettings.loopEnabled = false
    project.metronomeSettings.loopEndBar = 256
    let engine = MetronomeEngine()
    engine.onFailure = { Issue.record("Audio configuration changed during test: \($0)") }
    try engine.start(project: project)
    defer { engine.stop() }
    try await Task.sleep(for: .seconds(1))
    let initialTicks = engine.currentTicks()
    #expect(initialTicks > 0)
    let reference = ContinuousClock.now
    for step in 1...18 {
        try await Task.sleep(for: .seconds(10))
        try #require(engine.isPlaying, "Output device stopped during the live test")
        let elapsed = reference.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let observedSeconds = RhythmEngine.seconds(ticks: engine.currentTicks() - initialTicks, bpm: project.bpm)
        #expect(abs(observedSeconds - seconds) < 0.06)
        print("Live audio clock: \(step * 10)s, error \(String(format: "%.4f", observedSeconds - seconds))s")
    }
    engine.stop()
    let stopped = engine.currentTicks()
    try await Task.sleep(for: .milliseconds(150))
    #expect(engine.currentTicks() == stopped)
    try engine.returnToStart(project: project)
    #expect(engine.currentTicks() == 0)
    project.metronomeSettings.loopEnabled = true
    project.metronomeSettings.loopStartBar = 5
    project.metronomeSettings.loopEndBar = 8
    try engine.start(project: project)
    try await Task.sleep(for: .milliseconds(100))
    #expect(engine.currentTicks() >= 7680 && engine.currentTicks() < 15_360)
    project.bpm = 90
    try engine.reconfigure(project: project)
    #expect(engine.isPlaying)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VISIORHYTM_TRANSPORT_TEST"] == "1"))
@MainActor func singlePassStopsWithoutUIAndCanReplay() async throws {
    var project = Project()
    project.bpm = 240
    project.metronomeSettings.volume = 0
    project.metronomeSettings.loopEnabled = false
    project.metronomeSettings.loopStartBar = 2
    project.metronomeSettings.loopEndBar = 2
    let engine = MetronomeEngine()
    defer { engine.stop() }
    try engine.start(project: project)
    try await Task.sleep(for: .milliseconds(1300))
    #expect(!engine.isPlaying)
    #expect(engine.stoppedTicks == 3840)
    try engine.start(project: project)
    #expect(engine.isPlaying)
    #expect(engine.currentTicks() >= 1920 && engine.currentTicks() < 3840)
    engine.stop()
    try engine.returnToStart(project: project)
    #expect(engine.currentTicks() == 1920)

    project.metronomeSettings.loopEnabled = true
    try engine.start(project: project)
    try await Task.sleep(for: .milliseconds(1200))
    #expect(engine.isPlaying)
    project.metronomeSettings.loopEnabled = false
    project.metronomeSettings.loopEndBar = 3
    try engine.updatePlaybackRange(project: project)
    try await Task.sleep(for: .milliseconds(2300))
    #expect(!engine.isPlaying)
    #expect(engine.stoppedTicks == 5760)

    project.metronomeSettings.loopStartBar = 1
    project.metronomeSettings.loopEndBar = 8
    try engine.start(project: project)
    try await Task.sleep(for: .milliseconds(1100))
    project.metronomeSettings.loopEndBar = 1
    try engine.updatePlaybackRange(project: project)
    #expect(!engine.isPlaying)
    #expect(engine.stoppedTicks == 1920)
}
