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

    /// The filters and their memory, per channel. Touched only on the audio thread after `prepare`.
    private final class Processor {
        let settings: EQSettings
        var sampleRate = 44_100.0
        var interleaved = false
        var channels = 2
        var generation = -1
        var filters: [Biquad] = []
        /// Per channel, per filter: the transposed direct form II's two state values.
        var state: [[(Double, Double)]] = []

        init(settings: EQSettings) { self.settings = settings }

        func prepare(_ format: AudioStreamBasicDescription) {
            sampleRate = format.mSampleRate
            interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            channels = Int(format.mChannelsPerFrame)
            generation = -1
        }

        func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
            let (eq, generation) = settings.current
            if generation != self.generation {
                self.generation = generation
                let next = eq.isOn ? eq.filters(sampleRate: sampleRate) : []
                // Keep the filters' memory when only their settings move, so turning a knob doesn't click.
                if next.count != filters.count { state = [] }
                filters = next
            }
            guard !filters.isEmpty else { return }
            if state.count != channels {
                state = Array(repeating: Array(repeating: (0, 0), count: filters.count), count: channels)
            }
            if interleaved {
                guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
                for c in 0..<channels { run(data + c, stride: channels, frames: frames, channel: c) }
            } else {
                for (c, buffer) in buffers.enumerated() where c < channels {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    run(data, stride: 1, frames: frames, channel: c)
                }
            }
        }

        private func run(_ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int, channel: Int) {
            for (f, q) in filters.enumerated() {
                var (s1, s2) = state[channel][f]
                for i in 0..<frames {
                    let x = Double(samples[i * stride])
                    let y = q.b0 * x + s1
                    s1 = q.b1 * x - q.a1 * y + s2
                    s2 = q.b2 * x - q.a2 * y
                    samples[i * stride] = Float(y)
                }
                state[channel][f] = (s1, s2)
            }
        }
    }
}
