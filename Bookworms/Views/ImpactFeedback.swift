import AVFoundation
import CoreHaptics
import RealityKit
import os

/// A collision whose sound `ImpactFeedback` played, or would have played with **Sounds** on:
/// what an offline mix needs to play the same sound at the same time.
struct ImpactRecord: Equatable, Sendable {
    /// Seconds of simulation since the recording started.
    var time: TimeInterval
    /// The collision's impulse, in kilogram-units per second.
    var impulse: Float
    /// The heaviest moving body's mass, in kilograms.
    var mass: Float
    /// Where the bodies touched, in scene coordinates.
    var position: SIMD3<Float>
    /// The sound, one of `ImpactSound.bank`'s samples.
    var kind: ImpactSound.Kind
    var variant: Int
    /// How loud the sound plays, from 0 to 1, before `ImpactSound.level`.
    var volume: Float
    /// The sound's stereo position, from -1 at the screen's left edge to 1 at its right.
    var pan: Float
}

/// How hard collisions land, and the sounds they make, computed without audio hardware so an
/// offline renderer can mix the same sounds into a video.
enum ImpactSound {
    enum Kind: CaseIterable, Sendable {
        /// A heavy book's dull knock.
        case thud
        /// A light book's papery slap.
        case slap
    }

    static let sampleRate: Double = 44_100
    /// The gain of every voice. Eight full-strength thuds 30 ms apart, the most that overlap,
    /// sum to about 1.5, and panning a voice 0.8 to one side plays it at 0.99 there, so this
    /// keeps the mix below 0.9 without a limiter.
    static let level: Float = 0.6
    /// The variations of each kind, which differ in pitch and noise.
    static let variants = 4
    /// Books at least this heavy, in kilograms, thud; lighter books slap. In the pile, a
    /// 320-page book of average size weighs about 0.33 kg, and one of about 480 pages 0.5 kg,
    /// so about a third of a typical library thuds. A domino weighs 0.34 to 0.56 kg by its
    /// height (`DominoLayout.mass(height:)`).
    static let heavyMass: Float = 0.5
    /// Hits weaker than this are neither heard nor felt, so a settling pile stays quiet.
    static let threshold: Float = 0.04

    /// The change in speed, in units per second, that a hit in a pile needs to be heard at
    /// all, and the change at which it is as hard as hits get: a nudge, and a long fall.
    static let pileSpeeds: ClosedRange<Float> = 2...24
    /// The same for a domino chain, whose books tip into each other from standing, so a hit
    /// changes a book's speed by far less than a drop into a pile does. In a 39-book chain
    /// (`-BookwormsImpactLog YES`), half the hits change it by under 0.9 units per second, nine
    /// in ten by under 2.1, and the hardest, books landing flat on the table, by 3. Hits under
    /// about 0.4, the books settling, stay silent.
    static let dominoSpeeds: ClosedRange<Float> = 0.25...3.2

    /// How hard a hit lands, from 0 to 1: the moving book's change in speed, from the bottom of
    /// `speeds` up to its top, weighted by its mass, so a heavy book lands harder than a light
    /// one at the same speed.
    static func strength(
        impulse: Float, mass: Float, speeds: ClosedRange<Float> = pileSpeeds
    ) -> Float {
        let speed = impulse / max(mass, 0.05)
        let hardness = min(
            1, max(0, (speed - speeds.lowerBound) / (speeds.upperBound - speeds.lowerBound)))
        let weight = min(1.3, max(0.5, mass / 0.6))
        return min(1, hardness * weight)
    }

    static func kind(mass: Float) -> Kind { mass >= heavyMass ? .thud : .slap }

    /// The mono samples of a sound at `sampleRate`, peaking at 0.9. The same kind and variant
    /// always give the same samples.
    ///
    /// A thud is a low knock: a sine near 90 Hz that drops in pitch as it decays over about
    /// 0.2 seconds, an overtone, and a short burst of low noise for the contact. A slap is
    /// about 0.1 seconds of bright noise, like paper meeting paper, over a faint low body.
    static func samples(_ kind: Kind, variant: Int) -> [Float] {
        let pitch = 1 + (Float(variant) - Float(variants - 1) / 2) * 0.09
        var seed = UInt32(truncatingIfNeeded: 0x1234_5678 &+ variant &* 7919)
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 23) - 1
        }
        let duration = kind == .thud ? 0.24 : 0.12
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var low: Float = 0
        var high: Float = 0
        var phase: Float = 0
        let step = Float(1 / sampleRate)
        for index in 0..<count {
            let time = Float(index) * step
            let attack = min(1, time / 0.0015)
            let white = noise()
            switch kind {
            case .thud:
                let frequency = 88 * pitch * (1 + 0.35 * exp(-time / 0.02))
                phase += 2 * .pi * frequency * step
                // A one-pole low-pass keeps the contact's noise dull.
                low += (white - low) * 0.08
                samples[index] =
                    attack
                    * (sin(phase) * exp(-time / 0.055) + 0.35 * sin(2.6 * phase)
                        * exp(-time / 0.025) + 0.9 * low * exp(-time / 0.012))
            case .slap:
                // High-passed noise for the paper, over a quiet 170 Hz body.
                low += (white - low) * 0.25 * pitch
                high = white - low
                phase += 2 * .pi * 170 * pitch * step
                samples[index] =
                    attack
                    * (high * exp(-time / 0.016) + 0.25 * sin(phase) * exp(-time / 0.03))
            }
        }
        let peak = samples.map(abs).max() ?? 1
        return peak > 0 ? samples.map { $0 / peak * 0.9 } : samples
    }

    /// Every kind's variants, synthesized once.
    static let bank: [Kind: [[Float]]] = Dictionary(
        uniqueKeysWithValues: Kind.allCases.map { kind in
            (kind, (0..<variants).map { samples(kind, variant: $0) })
        })
}

/// Lets a burst of collisions through at a bounded rate: a hit passes if `interval` has gone by
/// since the last one that passed, or if it is half again as strong.
struct ImpactThrottle {
    let interval: TimeInterval
    private var last: (time: TimeInterval, strength: Float)?

    init(interval: TimeInterval) { self.interval = interval }

    mutating func admit(_ strength: Float, at time: TimeInterval) -> Bool {
        if let last, time - last.time < interval, strength <= last.strength * 1.5 {
            return false
        }
        last = (time, strength)
        return true
    }
}

/// Taps and knocks for collisions in a 3D scene.
///
/// The scene passes each `CollisionEvents.Began` to `collide(_:pan:)`. A hit plays a Core
/// Haptics tap whose intensity follows its strength (`ImpactSound.strength`, over the scene's
/// `speeds`), from a floor every admitted hit can be felt at, sharper for a light book, and,
/// while `playsSounds`, a short synthesized sound: a thud for a heavy book, a slap for a light
/// one, panned to where the hit shows on screen. Taps come at most every 60 ms and sounds every
/// 30 ms, unless a hit is much stronger (`ImpactThrottle`). Sounds take the variants in turn,
/// so a recording names the samples that played.
///
/// `ImpactAudio` plays the sounds away from the main actor. Devices without haptics, such as
/// the Simulator, only play sounds. `start` and `stop` bound both engines' lifetimes. The
/// haptic engine shuts itself down while no hit plays, such as while a chain stands waiting
/// for a push, and the next tap starts it again. The audio session's ambient category follows
/// the silent switch.
///
/// `startRecording` keeps every hit whose sound passes the throttle, with its simulation time,
/// until `finishRecording`, so an offline renderer can mix the same `ImpactSound` samples.
@MainActor
final class ImpactFeedback {
    /// Whether hits play sounds. **Sounds** in the desk's options menu sets it.
    var playsSounds = true {
        didSet {
            guard playsSounds != oldValue, isActive else { return }
            setAudio(playsSounds)
        }
    }
    /// The changes in speed that span a hit's strength, from barely audible to as hard as hits
    /// get, for the scene's kind of collisions (see `ImpactSound.strength`).
    var speeds = ImpactSound.pileSpeeds

    /// The least intensity a haptic tap plays at: lighter taps go unfelt in the hand.
    static let tapFloor: Float = 0.35

    nonisolated private static let log = Logger(
        subsystem: "gay.ian.Bookworms.iOS", category: "impacts")

    private let audio = ImpactAudio()
    /// Counts requests to start or stop `audio`, so it can ignore one that arrives late.
    private var audioRequest = 0
    private var isActive = false
    private var haptics: CHHapticEngine?
    /// Whether the haptic engine runs, which its idle shutdown and interruptions end.
    private var hapticsRunning = false
    private var hapticThrottle = ImpactThrottle(interval: 0.06)
    private var soundThrottle = ImpactThrottle(interval: 0.03)
    /// Counts the sounds, which take the variants in turn.
    private var sounds = 0
    /// Seconds of simulation, which `advance` counts.
    private var clock: TimeInterval = 0
    private var recording: (start: TimeInterval, records: [ImpactRecord])?

    /// Starts the haptic engine, and the audio engine while `playsSounds`.
    func start() {
        guard !isActive else { return }
        isActive = true
        startHaptics()
        if playsSounds { setAudio(true) }
    }

    /// Stops both engines and releases the audio session.
    func stop() {
        guard isActive else { return }
        isActive = false
        haptics?.stop()
        haptics = nil
        hapticsRunning = false
        setAudio(false)
    }

    /// Advances the clock that throttles and timestamps hits by one simulation step.
    func advance(by deltaTime: TimeInterval) { clock += deltaTime }

    /// Plays a collision between two bodies. `pan` gives a point's stereo position, from -1 at
    /// the screen's left edge to 1 at its right. Collisions between static bodies, such as the
    /// table and its walls, are ignored.
    func collide(_ event: CollisionEvents.Began, pan: (SIMD3<Float>) -> Float) {
        func mass(_ entity: Entity) -> Float? {
            guard let body = entity.components[PhysicsBodyComponent.self], body.mode != .static
            else { return nil }
            return body.massProperties.mass
        }
        guard let mass = [mass(event.entityA), mass(event.entityB)].compactMap(\.self).max(),
            event.impulse.isFinite
        else { return }
        impact(impulse: event.impulse, mass: mass, position: event.position, pan: pan)
    }

    /// Plays a hit of `impulse` on a body of `mass` at `position`, at least as hard as
    /// `minimum`, which lets a landing always be felt.
    func impact(
        impulse: Float, mass: Float, position: SIMD3<Float>,
        pan: (SIMD3<Float>) -> Float, minimum: Float = 0
    ) {
        let strength = max(
            minimum, ImpactSound.strength(impulse: impulse, mass: mass, speeds: speeds))
        var played = (tap: false, sound: false)
        #if DEBUG
            defer { logHit(impulse: impulse, mass: mass, strength: strength, played: played) }
        #endif
        guard strength >= ImpactSound.threshold else { return }
        // The throttle admits taps whether or not the hardware plays them, so a device plays
        // the same taps as the log counts.
        played.tap = hapticThrottle.admit(strength, at: clock)
        if played.tap, haptics != nil {
            tap(strength: strength, sharpness: mass < ImpactSound.heavyMass ? 0.6 : 0.25)
        }
        guard soundThrottle.admit(strength, at: clock) else { return }
        played.sound = true
        let kind = ImpactSound.kind(mass: mass)
        let variant = sounds % ImpactSound.variants
        let stereo = pan(position)
        sounds += 1
        if let start = recording?.start {
            recording?.records
                .append(
                    ImpactRecord(
                        time: clock - start, impulse: impulse, mass: mass, position: position,
                        kind: kind, variant: variant, volume: strength, pan: stereo))
        }
        guard isActive, playsSounds else { return }
        Task { [audio] in
            await audio.play(kind, variant: variant, volume: strength, pan: stereo)
        }
    }

    #if DEBUG
        /// Whether `-BookwormsImpactLog YES` asks for the hit log, read once.
        private static let logsHits = UserDefaults.standard.bool(forKey: "BookwormsImpactLog")
        private var hitLog: [String] = []

        /// Simulator hook: with `-BookwormsImpactLog YES`, appends every hit the scene reports
        /// to `Library/Caches/Bookworms/impact-log.csv`: the clock, its impulse, the body's mass,
        /// its strength, and whether it played a tap and a sound, which the throttles decide.
        /// The Simulator plays no haptics, so there `tap` says whether a device would have.
        /// The file is written every 20 hits.
        private func logHit(
            impulse: Float, mass: Float, strength: Float, played: (tap: Bool, sound: Bool)
        ) {
            guard Self.logsHits else { return }
            if hitLog.isEmpty { hitLog = ["clock,impulse,mass,strength,tap,sound"] }
            hitLog.append(
                [clock, Double(impulse), Double(mass), Double(strength)]
                    .map { String(format: "%.4f", $0) }
                    .joined(separator: ",") + ",\(played.tap ? 1 : 0),\(played.sound ? 1 : 0)")
            guard hitLog.count.isMultiple(of: 20) else { return }
            let url = URL.cachesDirectory.appending(path: "Bookworms/impact-log.csv")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? hitLog.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    #endif

    /// Starts keeping every hit whose sound passes the throttle, replacing a recording in
    /// progress.
    func startRecording() { recording = (clock, []) }

    /// The hits recorded so far, in the order they happened, while a recording runs.
    var recorded: [ImpactRecord] { recording?.records ?? [] }

    /// Stops recording and returns the hits in the order they happened.
    func finishRecording() -> [ImpactRecord] {
        defer { recording = nil }
        return recording?.records ?? []
    }

    private func setAudio(_ running: Bool) {
        audioRequest += 1
        let request = audioRequest
        Task { [audio] in await audio.run(running, request: request) }
    }

    // MARK: Haptics

    private func startHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
            let engine = try? CHHapticEngine()
        else { return }
        engine.playsHapticsOnly = true
        // The engine stops itself once no tap has played for a while, such as while a chain
        // stands waiting for a push; `tap` starts it again. A stopped engine ignores players.
        engine.isAutoShutdownEnabled = true
        engine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in self?.hapticsRunning = false }
        }
        engine.resetHandler = { [weak self] in
            Task { @MainActor in self?.hapticsRunning = false }
        }
        haptics = engine
        engine.start { [weak self] error in
            Task { @MainActor in self?.hapticsRunning = error == nil }
            if let error { Self.log.error("Haptics did not start: \(error)") }
        }
    }

    /// Plays a transient tap at least `tapFloor` strong, starting the engine again first if
    /// it stopped.
    private func tap(strength: Float, sharpness: Float) {
        guard let haptics else { return }
        if !hapticsRunning {
            guard (try? haptics.start()) != nil else { return }
            hapticsRunning = true
        }
        let intensity = Self.tapFloor + (1 - Self.tapFloor) * strength
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0)
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
            let player = try? haptics.makePlayer(with: pattern)
        else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }
}

/// Plays `ImpactSound`s through eight pooled voices, off the main actor: the audio session's
/// calls block, and starting the engine spins up audio I/O.
///
/// The session's ambient category mixes with other audio and follows the silent switch. The
/// session is deactivated only if this actor activated it. The engine is rebuilt after a route
/// change, such as headphones connecting, and after the media services reset. An interruption,
/// such as a call, stops the engine; it restarts at the next sound after the interruption
/// ends, at most once a second. A new sound takes over the oldest voice.
actor ImpactAudio {
    private static let voiceCount = 8
    private static let log = Logger(subsystem: "gay.ian.Bookworms.iOS", category: "impacts")

    private var request = 0
    private var isRunning = false
    private var engine: AVAudioEngine?
    private var voices: [AVAudioPlayerNode] = []
    private var buffers: [ImpactSound.Kind: [AVAudioPCMBuffer]] = [:]
    private var nextVoice = 0
    private var activatedSession = false
    private var observers: [any NSObjectProtocol] = []
    private var lastRestart: ContinuousClock.Instant?

    /// Starts or stops the engine. Requests may arrive out of order, so one older than the
    /// last request handled is ignored.
    func run(_ running: Bool, request: Int) {
        guard request > self.request else { return }
        self.request = request
        guard running != isRunning else { return }
        isRunning = running
        if running { setUp() } else { tearDown() }
    }

    /// Plays a variant of `kind` at `volume` (0 to 1), panned to `pan`, if the engine runs.
    func play(_ kind: ImpactSound.Kind, variant: Int, volume: Float, pan: Float) {
        guard let engine, let variants = buffers[kind], variants.indices.contains(variant)
        else { return }
        if !engine.isRunning {
            let now = ContinuousClock.now
            if let lastRestart, now - lastRestart < .seconds(1) { return }
            lastRestart = now
            do { try engine.start() } catch { return }
        }
        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        voice.volume = volume * ImpactSound.level
        voice.pan = min(1, max(-1, pan))
        voice.scheduleBuffer(variants[variant], at: nil, options: .interrupts)
        if !voice.isPlaying { try? voice.playAudio() }
    }

    private func setUp() {
        guard engine == nil,
            let format = AVAudioFormat(
                standardFormatWithSampleRate: ImpactSound.sampleRate, channels: 1)
        else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient)
            try session.setActive(true)
            activatedSession = true
        } catch {
            Self.log.error("The audio session did not activate: \(error)")
            return
        }
        let engine = AVAudioEngine()
        do {
            voices = try (0..<Self.voiceCount)
                .map { _ in
                    let voice = AVAudioPlayerNode()
                    engine.attach(voice)
                    try engine.connectNode(voice, to: engine.mainMixerNode, format: format)
                    return voice
                }
            if buffers.isEmpty {
                buffers = ImpactSound.bank.mapValues { variants in
                    variants.compactMap { samples in Self.buffer(samples, format: format) }
                }
            }
            engine.prepare()
            try engine.start()
        } catch {
            Self.log.error("The audio engine did not start: \(error)")
            tearDown()
            return
        }
        self.engine = engine
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in Task { await self?.rebuild() } },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                queue: nil
            ) { [weak self] _ in Task { await self?.rebuild() } },
        ]
    }

    /// Builds a new engine, keeping the session active.
    private func rebuild() {
        guard isRunning else { return }
        tearDown(releasingSession: false)
        setUp()
    }

    private func tearDown(releasingSession: Bool = true) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine?.stop()
        engine = nil
        voices = []
        nextVoice = 0
        guard releasingSession, activatedSession else { return }
        activatedSession = false
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            channel.update(from: $0.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
