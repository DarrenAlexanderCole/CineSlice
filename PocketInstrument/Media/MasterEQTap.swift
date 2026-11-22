import AVFoundation
import EditCore
import MediaToolbox
import os

/// The master EQ's settings as the audio thread reads them. Preview keeps one for the life of the
/// workspace, so a knob being turned is heard at once without swapping the player's mix; export
/// makes its own with the project's settings.
final class EQSettings: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (eq: MasterEQ.flat, generation: 0))

    init(_ eq: MasterEQ = .flat) { set(eq) }

    func set(_ eq: MasterEQ) {
        lock.withLock { state in
            guard state.eq != eq else { return }
            state = (eq, state.generation + 1)
        }
    }

    /// The settings and a number that changes whenever they do.
    var current: (eq: MasterEQ, generation: Int) { lock.withLock { $0 } }
}

/// The master EQ's taps for one player item (or export), one per audio track, made once and
/// handed back each time the item's audio mix is replaced. A mix with fresh taps makes the player
/// tear down and rebuild its audio, which stalls playback; replacing levels many times a second
/// (riding a fader, writing automation) froze it outright.
final class MasterEQTaps: @unchecked Sendable {
    let settings: EQSettings
    private let taps = OSAllocatedUnfairLock(uncheckedState: [CMPersistentTrackID: MTAudioProcessingTap]())

    init(_ settings: EQSettings) { self.settings = settings }

    func tap(for trackID: CMPersistentTrackID) -> MTAudioProcessingTap? {
        taps.withLockUnchecked { taps in
            if let tap = taps[trackID] { return tap }
            let tap = MasterEQTap.make(settings)
            taps[trackID] = tap
            return tap
        }
    }
}

/// Runs the master EQ on one audio track of a composition, as an `MTAudioProcessingTap` on its
/// mix parameters. EQ is linear, so the same filters on every track sound as they would on the
/// mixed bus.
enum MasterEQTap {
    static func make(_ settings: EQSettings) -> MTAudioProcessingTap? {
        let processor = Processor(settings: settings)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(processor).toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<Processor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<Processor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr
                else { return }
                Unmanaged<Processor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
            == noErr
        else {
            Unmanaged.passUnretained(processor).release()
            return nil
        }
        return tap
    }

    /// The filters and their memory, per channel. Touched only on the audio thread after
    /// `prepare`, where it never allocates or locks for long. Each band keeps its slot, and new
    /// settings glide in across one buffer, so turning a knob (even through 0 dB, where a band
    /// drops out) never clicks.
    private final class Processor {
        static let maxChannels = 16
        let settings: EQSettings
        var sampleRate = 44_100.0
        var interleaved = false
        var channels = 2
        var generation = -1
        /// What's playing, and where the next buffer glides to.
        var playing = MasterEQ.Bands()
        var target = MasterEQ.Bands()
        /// Per channel, per band: the transposed direct form II's two state values.
        let state = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * MasterEQ.Bands.count * 2)

        init(settings: EQSettings) {
            self.settings = settings
            state.initialize(repeating: 0, count: Self.maxChannels * MasterEQ.Bands.count * 2)
        }

        deinit { state.deallocate() }

        func prepare(_ format: AudioStreamBasicDescription) {
            sampleRate = format.mSampleRate
            interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            channels = min(Int(format.mChannelsPerFrame), Self.maxChannels)
            generation = -1
            state.update(repeating: 0, count: Self.maxChannels * MasterEQ.Bands.count * 2)
        }

        func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
            let (eq, generation) = settings.current
            if generation != self.generation {
                self.generation = generation
                target = eq.bands(sampleRate: sampleRate)
            }
            guard frames > 0, !(playing.isIdentity && target.isIdentity) else { return }
            if interleaved {
                guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
                for c in 0..<channels { run(data + c, stride: channels, frames: frames, channel: c) }
            } else {
                for (c, buffer) in buffers.enumerated() where c < channels {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    run(data, stride: 1, frames: frames, channel: c)
                }
            }
            playing = target
            if playing.isIdentity { state.update(repeating: 0, count: Self.maxChannels * MasterEQ.Bands.count * 2) }
        }

        private func run(_ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int, channel: Int) {
            for band in 0..<MasterEQ.Bands.count {
                let from = playing[band]
                let to = target[band]
                if from == .identity && to == .identity { continue }
                let s = state + (channel * MasterEQ.Bands.count + band) * 2
                var s1 = s[0]
                var s2 = s[1]
                let gliding = from != to
                var q = to
                for i in 0..<frames {
                    if gliding { q = from.mixed(with: to, Double(i + 1) / Double(frames)) }
                    let x = Double(samples[i * stride])
                    let y = q.b0 * x + s1
                    s1 = q.b1 * x - q.a1 * y + s2
                    s2 = q.b2 * x - q.a2 * y
                    samples[i * stride] = Float(y)
                }
                s[0] = s1
                s[1] = s2
            }
        }
    }
}
